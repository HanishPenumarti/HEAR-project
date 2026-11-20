#!/bin/bash
# Upload the scripts (not data) of this repo to <workdir>/hear_repro on the cluster.
# Needs: python with paramiko (set PYTHON if not "python"), and credentials (see tools/remote.py).
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PY="${PYTHON:-python}"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cd "$REPO" && tar --force-local -czf "$TMP/upload.tgz" build.sh build_*.sh jobs analysis control
"$PY" -I "$REPO/tools/remote.py" put "$TMP/upload.tgz" hear_repro/_upload.tgz >/dev/null
"$PY" -I "$REPO/tools/remote.py" run --timeout 120 <<'EOR'
mkdir -p hear_repro && cd hear_repro && tar xzf _upload.tgz --no-same-permissions && rm -f _upload.tgz
find . -maxdepth 2 \( -name "*.sh" -o -name "*.in" -o -name "*.py" -o -name "*.txt" -o -name "*.c" -o -name "*.cpp" \) -exec sed -i 's/\r$//' {} +
chmod -R a+rX jobs analysis control build.sh build_*.sh && echo "synced: $(ls jobs | tr '\n' ' ')"
EOR
