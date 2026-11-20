#!/bin/bash
# P3 (4 nodes, after the security job): the Fig 9 runs P2 could not finish.
# - ResNet-152 proxy: the authors' version (100 warm-up + 100 timed iterations) exceeded the
#   40-minute per-run limit at 80 ranks. control/resnet152_short.cpp is the same code with
#   5 warm-up + 10 timed iterations; it reports the same per-iteration average.
# - CosmoFlow and DLRM with the GCC 4.8.5 libhear build (P2 ran them with GCC 9.3 only).
ROOT="$1"; source "$ROOT/jobs/common.sh"; source "$ROOT/jobs/osu_lib.sh"
export I_MPI_FABRICS=shm:dapl
OUT="$RES/perf"; exec > "$OUT/perf_dnn2_$JOBNUM.log" 2>&1
H4=$(hosts_csv 4); H2=$(hosts_csv 2)
D="$OUT/logs_dnn"; mkdir -p "$D"
TMO=2400
hear_dnn() { HENV=(-genv LD_PRELOAD "$ROOT/$1/lib/libhear_release.so" -genv HEAR_ENABLE_AESNI 1 \
                   -genv HEAR_PIPELINING_BLOCK_SIZE 262144 -genv HEAR_MPOOL_SBUF_LEN 8388608); }
echo "== $(stamp) job $PBS_JOBID on ${NODES[*]}"
echo "== ResNet-152 proxy (5 warm-up + 10 timed iterations), 80 ranks"
native;               osu_run "$D/resnet.baseline.80.log"   80 20 "$H4" "$BIN/resnet_short"
hear_dnn build_gcc9;  osu_run "$D/resnet.hear-gcc9.80.log"  80 20 "$H4" "$BIN/resnet_short"
hear_dnn build;       osu_run "$D/resnet.hear-gcc48.80.log" 80 20 "$H4" "$BIN/resnet_short"
grep -h "each iteration" "$D"/resnet.*.80.log
echo "== ResNet-152 proxy, 40 ranks"
native;               osu_run "$D/resnet.baseline.40.log"   40 20 "$H2" "$BIN/resnet_short"
hear_dnn build_gcc9;  osu_run "$D/resnet.hear-gcc9.40.log"  40 20 "$H2" "$BIN/resnet_short"
echo "== CosmoFlow and DLRM with the GCC 4.8.5 build, 80 ranks"
for app in cosmoflow dlrm; do
    hear_dnn build; osu_run "$D/$app.hear-gcc48.80.log" 80 20 "$H4" "$BIN/$app"
done
grep -h "iteration" "$D"/*.log
echo "== $(stamp) perf_dnn2 done"
