#!/bin/bash
# L (1 node): Fig 3 precision loss + correctness tests in parallel on separate cores.
# (Fig 5 runs as its own job, jobs/fig5.sh: python3 is not installed on compute
#  nodes, and the throughput test should have the node to itself.)
ROOT="$1"; source "$ROOT/jobs/common.sh"
OUT="$RES/local"; mkdir -p "$OUT"; chmod 777 "$OUT" 2>/dev/null
exec > "$OUT/local_$JOBNUM.log" 2>&1
echo "== $(stamp) job $PBS_JOBID on $(hostname)"
lscpu | grep -E "Model name|CPU max MHz"; echo "no_turbo=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo)"

echo "== Fig 3 precision (MPFR 4.1.0) + correctness, in parallel"
mkdir -p "$OUT/accuracy/tests/accuracy/results" "$OUT/correctness"
cd "$OUT/accuracy"
( time taskset -c 2 "$BIN/accuracy_addition" -n combined ) > addition.log 2>&1 &
( time taskset -c 4 "$BIN/accuracy_multiplication" -n new -t 10000 ) > multiplication.log 2>&1 &
cd "$OUT/correctness"
( time taskset -c 6 "$BIN/integer_correctness"; echo "integer_correctness exit=$?" ) > integer.log 2>&1 &
( time taskset -c 8 "$BIN/hfloat_correctness"; echo "hfloat_correctness exit=$?" ) > hfloat.log 2>&1 &
wait
echo "$(stamp) all done"
tail -3 "$OUT"/correctness/*.log "$OUT"/accuracy/*.log
ls -la "$OUT/accuracy/tests/accuracy/results/"
