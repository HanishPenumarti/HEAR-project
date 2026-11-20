#!/bin/bash
# Download result logs from <workdir>/hear_repro/results into data/ours, fetch the authors'
# precision CSVs (from the cluster's libhear clone) into data/authors/accuracy, and run
# parse -> summarize -> export.
# Needs: python with paramiko, pandas, numpy (set PYTHON if not "python").
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PY="${PYTHON:-python}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
"$PY" -I "$REPO/tools/remote.py" run --timeout 300 <<'EOR' >/dev/null || { echo "remote tar failed"; exit 1; }
cd hear_repro/results && rm -f ../_fetch.tgz
items=$(ls -d perf compilers local/logs_single_core_tput local/accuracy/tests/accuracy/results local/correctness local/*.log security/tests/security/mantissas_total.csv security/*.log probe 2>/dev/null)
tar czf ../_fetch.tgz $items -C ../libhear tests/accuracy/results
EOR
"$PY" -I "$REPO/tools/remote.py" get hear_repro/_fetch.tgz "$TMP/_fetch.tgz" >/dev/null
"$PY" -I "$REPO/tools/remote.py" run --timeout 60 <<<'rm -f hear_repro/_fetch.tgz' >/dev/null
F="$TMP/fetch"; mkdir -p "$F" && tar --force-local -xzf "$TMP/_fetch.tgz" -C "$F"
O="$REPO/data/ours"; A="$REPO/data/authors/accuracy"
mkdir -p "$O/raw" "$O/accuracy" "$O/correctness" "$O/security" "$O/joblogs" "$A"
cp -r "$F/perf/"logs_* "$O/raw/" 2>/dev/null
rm -rf "$O/dcheck"; mkdir -p "$O/dcheck"; cp "$F/perf/logs_dcheck/"*.log "$O/dcheck/" 2>/dev/null
cp -r "$F/local/logs_single_core_tput" "$O/raw/" 2>/dev/null
rm -rf "$O/raw/compilers"; cp -r "$F/compilers" "$O/raw/" 2>/dev/null
cp "$F/local/accuracy/tests/accuracy/results/"*.csv "$O/accuracy/" 2>/dev/null
cp "$F/tests/accuracy/results/"*.csv "$A/" 2>/dev/null
cp "$F/local/correctness/"*.log "$O/correctness/" 2>/dev/null
cp "$F/security/tests/security/mantissas_total.csv" "$O/security/" 2>/dev/null
cp "$F/perf/"*.log "$F/local/"*.log "$F/security/"*.log "$O/joblogs/" 2>/dev/null
cp -r "$F/probe" "$O/joblogs/" 2>/dev/null
"$PY" -I "$REPO/analysis/parse_logs.py" "$O/raw" "$O" ours && \
"$PY" -I "$REPO/analysis/summarize.py" "$REPO/data" "$A" "$REPO/data/results.json" && \
"$PY" -I "$REPO/analysis/export_datasets.py" "$REPO/data" "$REPO/datasets"
