#!/bin/bash
# S (4 nodes): §5.3.1 security experiment. Exhaustive MAP-adversary likelihood:
# every IEEE-754 FP32 plaintext mantissa (2^23) x every noise mantissa (2^21).
# Deterministic, so the paper's numbers should be reproduced exactly.
ROOT="$1"; source "$ROOT/jobs/common.sh"
export I_MPI_FABRICS=shm:dapl
OUT="$RES/security"; mkdir -p "$OUT/tests/security"; chmod -R 777 "$OUT" 2>/dev/null
exec > "$OUT/security_$JOBNUM.log" 2>&1
echo "== $(stamp) job $PBS_JOBID on ${NODES[*]}"
cd "$OUT"
time mpirun -n 80 -ppn 20 -hosts "$(hosts_csv 4)" "$BIN/security_80"
echo "== $(stamp) security done, rc=$?"
ls -la tests/security | head; du -sh tests/security
