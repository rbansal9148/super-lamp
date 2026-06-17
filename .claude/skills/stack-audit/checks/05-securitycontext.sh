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

            # ── baseline tallies (aggregated below) ──
            # A container ALLOWLISTED for special privileges (SECCTX_ADDED_CAPS_ALLOW, e.g.
            # gluetun: a VPN gateway that CANNOT drop caps / run non-root without breaking its
            # /dev/net/tun device — documented in its manifest) is a known exception, not a
            # baseline gap. Counting it emits a PERMANENT false-positive LOW every run, which
            # trains the operator to ignore the line. Exclude it from the three baseline nags —
            # it is still subject to the per-container HIGH checks above (priv/root/dangerous
            # caps), and a DIFFERENT container regressing is still counted (unlike a blanket
            # .audit-ignore on the aggregate line, which would mask that regression).
            if cn in allow_caps:
                continue
            if not (nonroot is True or (isinstance(run_as, int) and run_as != 0)):
                no_nonroot += 1
            if "ALL" not in dropped:
                no_dropall += 1
            if ape is not False:
                no_ape += 1

    if total:
        if no_nonroot:
            print(f"LOW|security/nonroot|{ns}: {no_nonroot}/{total} containers don't enforce runAsNonRoot (may run as root)|set runAsNonRoot: true / a non-zero runAsUser where the image allows")
        if no_dropall:
            print(f"LOW|security/caps|{ns}: {no_dropall}/{total} containers don't drop ALL capabilities|add securityContext.capabilities.drop: [ALL] where the image allows")
        if no_ape:
            print(f"LOW|security/escalation|{ns}: {no_ape}/{total} containers allow privilege escalation|set allowPrivilegeEscalation: false where the image allows")
PY
