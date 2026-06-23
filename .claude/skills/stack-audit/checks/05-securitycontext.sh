#!/bin/bash
# Pod securityContext hardening (k8s). Static config quality, no metric → audit-only.
# Calibrated to avoid noise: the GENUINE escape/root risks are flagged per-container at
# HIGH/MED; the broad baseline gap (most images here run with the default context —
# potentially root, caps not dropped, escalation allowed) is reported as a few AGGREGATE
# LOW lines per namespace rather than ~70 per-container lines that would drown the signal.
#
#   HIGH  privileged:true · hostNetwork/PID/IPC · explicit runAsUser:0 · dangerous added cap
#   LOW   (aggregate) "N/M containers don't enforce runAsNonRoot / drop ALL caps / set APE=false"
#
# Remediating the baseline is per-image work (some images break as non-root / need a cap),
# which is why it's LOW, not a per-container MED nag. Scoped to owned namespaces.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"
command -v kubectl >/dev/null 2>&1 || { echo "LOW|audit/05-securitycontext|kubectl not on PATH — securityContext audit skipped|install kubectl / check KUBECONFIG"; exit 0; }
# Reachability gate: an unreachable cluster otherwise writes empty per-ns JSON → python
# hits except:continue → zero findings, indistinguishable from a fully-hardened stack.
kubectl get --raw='/healthz' --request-timeout=5s >/dev/null 2>&1 || { echo "LOW|audit/05-securitycontext|cannot reach cluster — securityContext check skipped, result is INCONCLUSIVE (not clean)|check KUBECONFIG / cluster reachability"; exit 0; }

# Containers permitted to add caps / run privileged (real need). gluetun runs the VPN
# tunnel and legitimately needs NET_ADMIN (+ a tun device).
: "${SECCTX_ADDED_CAPS_ALLOW:=gluetun}"
# Caps that are escape-grade if added.
: "${SECCTX_DANGEROUS_CAPS:=ALL SYS_ADMIN SYS_PTRACE SYS_MODULE SYS_RAWIO NET_RAW BPF}"
OWNED="${RESOURCE_OWNED_NAMESPACES:-apps observability}"

TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
for ns in $OWNED; do
  kubectl get pods -n "$ns" -o json 2>/dev/null > "$TMPD/$ns.json"
done

# Pass the allowlist + dangerous-cap set INLINE: they're set with `:=` above (bash-local,
# NOT exported), so the python child wouldn't otherwise inherit them — allow_caps/danger
# would silently fall back to empty, dead-lettering both the caps-add allowlist and the
# baseline-tally exemption. (Same export-trap as the thresholds.sh fix.)
NS_LIST="$OWNED" TMPD="$TMPD" \
  SECCTX_ADDED_CAPS_ALLOW="$SECCTX_ADDED_CAPS_ALLOW" \
  SECCTX_DANGEROUS_CAPS="$SECCTX_DANGEROUS_CAPS" \
  python3 - <<'PY'
import json, os

allow_caps = set((os.environ.get("SECCTX_ADDED_CAPS_ALLOW") or "").split())
danger     = set((os.environ.get("SECCTX_DANGEROUS_CAPS") or "").split())
_d = os.environ["TMPD"]

for ns in (os.environ.get("NS_LIST") or "").split():
    try:
        items = json.load(open(f"{_d}/{ns}.json")).get("items", [])
    except Exception:
        continue
    total = 0
    no_nonroot = 0
    no_dropall = 0
    no_ape = 0
    no_seccomp = 0   # seccompProfile.type not RuntimeDefault/Localhost → unconfined syscall surface
    no_rofs = 0      # readOnlyRootFilesystem not True → writable container root
    for pod in items:
        if pod.get("status", {}).get("phase") != "Running":
            continue
        spec = pod.get("spec", {})
        name = pod.get("metadata", {}).get("name", "?")
        psc  = spec.get("securityContext", {}) or {}

        # ── pod-level host namespaces (HIGH) ──
        for hk, label in (("hostNetwork","hostNetwork"),("hostPID","hostPID"),("hostIPC","hostIPC")):
            if spec.get(hk):
                print(f"HIGH|security/hostns|{ns}/{name} sets {label}: true — shares the host {label} namespace, breaks pod isolation|remove {hk} unless strictly required")

        for c in spec.get("containers", []):
            total += 1
            cn  = c.get("name","?")
            sc  = c.get("securityContext", {}) or {}
            priv = sc.get("privileged", False)
            ape  = sc.get("allowPrivilegeEscalation", psc.get("allowPrivilegeEscalation"))
            nonroot = sc.get("runAsNonRoot", psc.get("runAsNonRoot"))
            run_as  = sc.get("runAsUser", psc.get("runAsUser"))
            caps    = sc.get("capabilities", {}) or {}
            dropped = set(caps.get("drop", []) or [])
            added   = set(caps.get("add", []) or [])

            # ── per-container HIGH ──
            if priv:
                print(f"HIGH|security/privileged|{ns}/{name} container {cn} is privileged — full host access, container escape|set securityContext.privileged: false")
            if run_as == 0:
                print(f"HIGH|security/root|{ns}/{name} container {cn} explicitly runAsUser: 0 (root)|run as a non-zero UID")
            bad_added = (added & danger) if cn not in allow_caps else set()
            if bad_added:
                print(f"MED|security/caps-add|{ns}/{name} container {cn} adds escape-grade capabilit{'ies' if len(bad_added)>1 else 'y'} {sorted(bad_added)}|drop these unless required (allowlist via SECCTX_ADDED_CAPS_ALLOW)")
            # SETUID/SETGID added + not pinned non-root: the process can change its effective
            # UID/GID if it starts as root. Common in s6/gosu PUID-drop images (calibre-web,
            # prowlarr) where it's intentional — but it IS a real escalation surface, so surface
            # it (suppress known-intentional ones via .audit-ignore). Allowlist-exempt like the
            # escape-grade caps above; distinct from them (SETUID/SETGID are not in `danger`).
            setid = added & {"SETUID", "SETGID"}
            if cn not in allow_caps and setid and not (nonroot is True or (isinstance(run_as, int) and run_as != 0)):
                print(f"MED|security/caps-setuid|{ns}/{name} container {cn} adds {sorted(setid)} without runAsNonRoot — can change effective UID if it starts as root|set runAsNonRoot: true / a non-zero runAsUser, or drop SETUID/SETGID if unused")

            # ── baseline tallies (aggregated below) ──
            # seccompProfile is tallied for ALL containers, INCLUDING allowlisted ones — it is
            # pulled ABOVE the allow_caps `continue` below on purpose. A RuntimeDefault/Localhost
            # profile confines the syscall surface, and that is ORTHOGONAL to the cap/root
            # exception: gluetun needs NET_ADMIN + root for its tun device, but it can still run
            # RuntimeDefault seccomp. Skipping it here hid gluetun's Unconfined profile — the
            # widest syscall surface in the stack (NET_ADMIN routes all cluster egress) — from
            # the tally. Honour container OR pod-level securityContext.
            sec_type = ((sc.get("seccompProfile") or {}).get("type")
                        or (psc.get("seccompProfile") or {}).get("type"))
            if sec_type not in ("RuntimeDefault", "Localhost"):
                no_seccomp += 1
            # A container ALLOWLISTED for special privileges (SECCTX_ADDED_CAPS_ALLOW, e.g.
            # gluetun: a VPN gateway that CANNOT drop caps / run non-root without breaking its
            # /dev/net/tun device — documented in its manifest) is a known exception for the
            # runAsNonRoot / drop-ALL / no-escalation nags — counting those emits a PERMANENT
            # false-positive LOW that trains the operator to ignore the line. It is still subject
            # to the per-container HIGH checks above (priv/root/dangerous caps), the seccomp tally
            # above, and a DIFFERENT container regressing is still counted (unlike a blanket
            # .audit-ignore on the aggregate line, which would mask that regression).
            if cn in allow_caps:
                continue
            if not (nonroot is True or (isinstance(run_as, int) and run_as != 0)):
                no_nonroot += 1
            if "ALL" not in dropped:
                no_dropall += 1
            if ape is not False:
                no_ape += 1
            # readOnlyRootFilesystem: a writable container root is a tampering/persistence surface.
            if sc.get("readOnlyRootFilesystem") is not True:
                no_rofs += 1

    if total:
        if no_nonroot:
            print(f"LOW|security/nonroot|{ns}: {no_nonroot}/{total} containers don't enforce runAsNonRoot (may run as root)|set runAsNonRoot: true / a non-zero runAsUser where the image allows")
        if no_dropall:
            print(f"LOW|security/caps|{ns}: {no_dropall}/{total} containers don't drop ALL capabilities|add securityContext.capabilities.drop: [ALL] where the image allows")
        if no_ape:
            print(f"LOW|security/escalation|{ns}: {no_ape}/{total} containers allow privilege escalation|set allowPrivilegeEscalation: false where the image allows")
        if no_seccomp:
            print(f"LOW|security/seccomp|{ns}: {no_seccomp}/{total} containers don't set a seccompProfile (RuntimeDefault) — syscall surface unconfined|set securityContext.seccompProfile.type: RuntimeDefault where the image allows")
        if no_rofs:
            print(f"LOW|security/readonly-root|{ns}: {no_rofs}/{total} containers have a writable root filesystem|set securityContext.readOnlyRootFilesystem: true (+ emptyDir/volume for writable paths) where the image allows")
PY
