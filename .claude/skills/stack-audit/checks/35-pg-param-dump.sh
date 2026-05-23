#!/bin/bash
# Postgres slow-query logging without parameter truncation dumps every
# slow statement's parameter values — for bitmagnet/stremthru that means
# bytea info_hash/file blobs printed as multi-MB hex strings (one slow
# torznab search filled a 9.6MB log file in this stack).
#
# Setting log_min_duration_statement should be paired with
# log_parameter_max_length=0 (and _on_error=0) to keep the timing+text
# but drop the parameter values.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../thresholds.sh"

for f in /opt/docker/apps/*/compose.yaml; do
  svc=$(basename "$(dirname "$f")")
  # Only postgres-style services
  grep -q 'log_min_duration_statement' "$f" || continue
  has_param_max=$(grep -c 'log_parameter_max_length' "$f")
  if [ "$has_param_max" -lt 1 ]; then
    echo "MED|postgres/${svc}|log_min_duration_statement set without log_parameter_max_length — slow-query bytea params dumped as multi-MB hex lines|add '-c log_parameter_max_length=0' and '-c log_parameter_max_length_on_error=0' to apps/${svc}/compose.yaml postgres command"
  fi
done
