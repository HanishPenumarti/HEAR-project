#!/bin/bash
# Fig 5: single-core encryption/decryption throughput, alone on an idle node, core 0.
# Bash port of the authors' scripts/single_core_encr_tput.py (python3 is not installed
# on the compute nodes): same binary, 1000 iterations, 2^1..2^21 items, same 5 PRFs.
ROOT="$1"; source "$ROOT/jobs/common.sh"
OUT="$RES/local"; D="$OUT/logs_single_core_tput"; mkdir -p "$D"; chmod 777 "$OUT" "$D" 2>/dev/null
exec > "$OUT/fig5_$JOBNUM.log" 2>&1
echo "== $(stamp) job $PBS_JOBID on $(hostname) no_turbo=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo)"
for dtype in int float; do
  for func in naive sha1sse2 sha1avx2 aesni aesni_unroll; do
    for j in $(seq 1 21); do
      n=$((2**j))
      taskset -c 0 "$BIN/encr_perf_test" 1000 $n 1 $dtype sum $func \
          > "$D/single_core_encr_tput.$dtype.sum.$func.$n.log" 2>&1
    done
    echo "$(stamp) $dtype/$func (2M items): $(grep -h 'throughput' "$D/single_core_encr_tput.$dtype.sum.$func.2097152.log" | awk '{printf "%s %s GB/s; ", $2, $4}')"
  done
done
echo "== $(stamp) done"
