#!/bin/bash
# Usage (from <workdir>/hear_repro):  bash jobs/submit.sh jobs/<name>.pbs.in [...]
# Jobs run as another account (site qsub wrapper), so $HOME inside a job is not
# ours: substitute the absolute hear_repro path for @ROOT@, then submit.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for tmpl in "$@"; do
    out="$ROOT/jobs/$(basename "${tmpl%.in}")"
    sed -e "s|@ROOT@|$ROOT|g" "$tmpl" > "$out"
    jobid=$(qsub "$out" 2>/dev/null)
    echo "$(date '+%F %T') $jobid $(basename "$out")" >> "$ROOT/jobs/submitted.log"
    echo "$jobid"
done
