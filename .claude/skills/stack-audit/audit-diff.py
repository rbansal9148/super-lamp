#!/usr/bin/env python3
"""Classify the current audit findings against a persisted prior run.

Inputs (both JSON arrays of {severity,domain,finding,fix}, as emitted by `audit.sh --json`):
  argv[1] = baseline (the prior persisted run, audit-log/latest.json)
  argv[2] = current  (this run)

Emits a markdown "Change vs last persisted run" section, or a sentinel:
  __NO_BASELINE__  baseline file absent/unreadable (first run) → caller prints a hint
  _NOCHANGE_       findings identical by stable identity → caller may stay quiet

STABLE IDENTITY: two findings are "the same finding" when their (domain, normalized
finding text) match — where normalization strips VOLATILE substrings so a finding whose
only run-to-run change is a live number or a rolled-over pod name reads as CHANGED (or
unchanged), never as NEW+CLEARED. Masked: k8s pod-name suffixes (deployment RS hash +
ordinal) and all digit runs (counts like "2/34", ports, percentages). Severity is compared
SEPARATELY on matched identities, so "2/34 → 3/34" is unchanged-identity and a LOW→MED bump
is a SEVERITY-CHANGED, not a churn of one cleared + one new.
"""
import json, re, sys

def norm(domain, finding):
    s = finding
    # deployment / replicaset pod suffix: -<rs-hash>-<pod-hash>  (e.g. -76467cbf68-6k8wm)
    s = re.sub(r'-[a-z0-9]{6,10}-[a-z0-9]{4,5}\b', '-POD', s)
    # statefulset ordinal pod suffix: -0, -1, …
    s = re.sub(r'-\d{1,3}\b', '-N', s)
    # any remaining digit run: counts ("2/34"), percentages, ports, sizes
    s = re.sub(r'\d+', 'N', s)
    return domain + '||' + s

def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None

base = load(sys.argv[1])
if base is None:
    print("__NO_BASELINE__")
    sys.exit(0)
cur = load(sys.argv[2]) or []

def index(arr):
    d = {}
    for it in arr:
        d[norm(it.get('domain', ''), it.get('finding', ''))] = it
    return d

bi, ci = index(base), index(cur)
new      = [ci[k] for k in ci if k not in bi]
cleared  = [bi[k] for k in bi if k not in ci]
changed  = [(bi[k], ci[k]) for k in ci if k in bi and bi[k].get('severity') != ci[k].get('severity')]

if not (new or cleared or changed):
    print("_NOCHANGE_")
    sys.exit(0)

SEVRANK = {'CRIT': 0, 'HIGH': 1, 'MED': 2, 'LOW': 3, 'OK': 4}
def sk(it):
    return (SEVRANK.get(it.get('severity'), 9), it.get('domain', ''), it.get('finding', ''))

print("## 🔁 Change vs last persisted run")
if new:
    print(f"\n### 🆕 New ({len(new)})")
    for it in sorted(new, key=sk):
        print(f"- **[{it.get('severity')}]** [{it.get('domain')}] {it.get('finding')}")
if changed:
    print(f"\n### 🔀 Severity changed ({len(changed)})")
    for b, c in sorted(changed, key=lambda p: sk(p[1])):
        print(f"- [{c.get('domain')}] {c.get('finding')}: **{b.get('severity')} → {c.get('severity')}**")
if cleared:
    print(f"\n### ✅ Cleared ({len(cleared)})")
    for it in sorted(cleared, key=sk):
        print(f"- ~~[{it.get('severity')}]~~ [{it.get('domain')}] {it.get('finding')}")
