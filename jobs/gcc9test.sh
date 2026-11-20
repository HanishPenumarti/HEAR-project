#!/bin/bash
# Quick check (1 node): does GCC 9 restore the compiler-vectorized AES-NI speed?
# Compares the GCC 4.8.5 and GCC 9.3 builds of the authors' encr_perf_test on core 0,
# then checks the GCC 9 libhear end to end (DCHECK memcmp, int sum, 20 ranks).
ROOT="$1"; source "$ROOT/jobs/common.sh"
OUT="$RES/gcc9"; mkdir -p "$OUT"; chmod 777 "$OUT" 2>/dev/null
exec > "$OUT/gcc9test_$JOBNUM.log" 2>&1
echo "== $(stamp) job $PBS_JOBID on $(hostname)"
for build in build build_gcc9; do
  for spec in "int aesni" "int aesni_unroll" "float aesni_unroll"; do
    set -- $spec
    for n in 65536 2097152; do
      r=$(taskset -c 0 "$ROOT/$build/bin/encr_perf_test" 1000 $n 1 $1 sum $2 | awk '/throughput/{printf "%s=%s ", $2, $4}')
      echo "$build $1 $2 items=$n $r"
    done
  done
done
echo "== DCHECK with the GCC 9 libhear (pipelined, int sum, 20 ranks on 1 node)"
mpirun -n 20 -ppn 20 -hosts "$(hosts_csv 1)" -genv LD_PRELOAD "$ROOT/build_gcc9/lib/libhear_dcheck_pipelined.so" \
    -genv HEAR_ENABLE_AESNI 1 -genv HEAR_PIPELINING_BLOCK_SIZE 65536 -genv HEAR_MPOOL_SBUF_LEN 2097152 \
    "$BIN/osu_allreduce_int" -m 4:16777216 -i 10 -x 2 > "$OUT/dcheck_gcc9.log" 2>&1
echo "dcheck_gcc9 rc=$? sizes=$(grep -cE '^[0-9]+ ' "$OUT/dcheck_gcc9.log")"
echo "== $(stamp) done"
