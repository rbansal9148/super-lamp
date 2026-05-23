#!/bin/bash
# Letsencrypt cert expiry via traefik's acme.json. Traefik renews
# automatically at ~30 days before expiry, but the renewal can fail
# silently (DNS challenge misconfigured, rate-limit hit, port 80 closed).
# A surfaced expiry within the renewal window is a "you should look
# now" signal, not a passive observation.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

: "${CERT_EXPIRY_WARN_DAYS:=30}"
: "${CERT_EXPIRY_CRIT_DAYS:=7}"

acme=/opt/docker/data/traefik/acme.json
sudo test -f "$acme" || exit 0
command -v openssl >/dev/null 2>&1 || exit 0

# acme.json may not be readable as non-root
sudo cat "$acme" 2>/dev/null | python3 -c "
import json, sys, base64, subprocess, datetime
warn = ${CERT_EXPIRY_WARN_DAYS}
crit = ${CERT_EXPIRY_CRIT_DAYS}
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
now = datetime.datetime.now(datetime.timezone.utc)
for r in d.values():
    for c in (r.get('Certificates') or []):
        try:
            pem = base64.b64decode(c['certificate']).decode()
            dom = c.get('domain', {}).get('main', '?')
            res = subprocess.run(['openssl','x509','-noout','-enddate'],
                                  input=pem, capture_output=True, text=True)
            end = res.stdout.strip().split('=')[1]
            exp = datetime.datetime.strptime(end, '%b %d %H:%M:%S %Y %Z').replace(tzinfo=datetime.timezone.utc)
            days = (exp - now).days
            if days <= crit:
                print(f'CRIT|tls|cert for {dom} expires in {days}d — renewal failed|check traefik logs for ACME errors; verify DNS challenge / port 80')
            elif days <= warn:
                print(f'MED|tls|cert for {dom} expires in {days}d — renewal due any day|monitor traefik logs; should auto-renew via ACME')
        except Exception:
            pass
"
