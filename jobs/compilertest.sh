#!/bin/bash
# Compiler comparison (1 node): the authors' encr_perf_test built with GCC 4.8.5, GCC 9.3
# and Intel icpc 18, on core 0, plus an end-to-end DCHECK (memcmp) of the icpc libhear.
ROOT="$1"; source "$ROOT/jobs/common.sh"
. /opt/apps/intel/compilers_and_libraries_2018.2.199/linux/bin/compilervars.sh intel64   # icpc runtime libs
OUT="$RES/compilers"; mkdir -p "$OUT"; chmod 777 "$OUT" 2>/dev/null
exec > "$OUT/compilertest_$JOBNUM.log" 2>&1
echo "== $(stamp) job $PBS_JOBID on $(hostname)"
for build in build build_gcc9 build_icc; do
  for spec in "int aesni" "int aesni_unroll" "float aesni_unroll"; do
    set -- $spec
    for n in 65536 2097152; do
      r=$(taskset -c 0 "$ROOT/$build/bin/encr_perf_test" 1000 $n 1 $1 sum $2 | awk '/throughput/{printf "%s=%s ", $2, $4}')
      echo "$build $1 $2 items=$n $r"
    done
  done
done
echo "== DCHECK with the icpc libhear (pipelined, int sum, 20 ranks on 1 node)"
mpirun -n 20 -ppn 20 -hosts "$(hosts_csv 1)" -genv LD_PRELOAD "$ROOT/build_icc/lib/libhear_dcheck_pipelined.so" \
    -genv HEAR_ENABLE_AESNI 1 -genv HEAR_PIPELINING_BLOCK_SIZE 65536 -genv HEAR_MPOOL_SBUF_LEN 2097152 \
    "$BIN/osu_allreduce_int" -m 4:16777216 -i 10 -x 2 > "$OUT/dcheck_icc.log" 2>&1
echo "dcheck_icc rc=$? sizes=$(grep -cE '^[0-9]+ ' "$OUT/dcheck_icc.log")"
echo "== $(stamp) done"
