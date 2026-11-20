#!/bin/bash
# Fig 5, selected dtypes only (default: float). Same measurement as fig5.sh; used to
# finish the float half after the first job hit its walltime (the unvectorized SHA1
# baseline runs at ~0.01-0.03 GB/s, so its 8 MiB buffers take minutes each).
# The authors' encr_perf_test supports only naive + aesni_unroll for floats.
ROOT="$1"; DTYPES="${2:-float}"; source "$ROOT/jobs/common.sh"
OUT="$RES/local"; D="$OUT/logs_single_core_tput"; mkdir -p "$D"
exec > "$OUT/fig5b_$JOBNUM.log" 2>&1
echo "== $(stamp) job $PBS_JOBID on $(hostname) dtypes=$DTYPES no_turbo=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo)"
for dtype in $DTYPES; do
  if [ "$dtype" = float ]; then funcs="aesni_unroll naive"; else funcs="naive sha1sse2 sha1avx2 aesni aesni_unroll"; fi
  for func in $funcs; do
    for j in $(seq 1 21); do
      n=$((2**j))
      taskset -c 0 "$BIN/encr_perf_test" 1000 $n 1 $dtype sum $func \
          > "$D/single_core_encr_tput.$dtype.sum.$func.$n.log" 2>&1
    done
    echo "$(stamp) $dtype/$func (2M items): $(grep -h 'throughput' "$D/single_core_encr_tput.$dtype.sum.$func.2097152.log" | awk '{printf "%s %s GB/s; ", $2, $4}')"
  done
done
echo "== $(stamp) done"
