#!/bin/bash
# P2 (4 nodes): node-scaling point of Fig 7/8 (80 ranks = 4 x 20) with synchronous HEAR and
# the chunked-MPI control, then (perf4_tail.sh) Fig 9 DNN proxies and the progress diagnostic.
ROOT="$1"; source "$ROOT/jobs/common.sh"; source "$ROOT/jobs/osu_lib.sh"
export I_MPI_FABRICS=shm:dapl
OUT="$RES/perf"; mkdir -p "$OUT"; chmod 777 "$OUT" 2>/dev/null
exec > "$OUT/perf4_$JOBNUM.log" 2>&1
H4=$(hosts_csv 4); H2=$(hosts_csv 2)
echo "== $(stamp) job $PBS_JOBID on ${NODES[*]} fabric=$I_MPI_FABRICS"

echo "== Fig 7/8 node scaling: 80 ranks (4 nodes x 20), int sum, 2 trials (+ synchronous HEAR)"
WITH_SYNC=1 scaling_point int 80 20 "$H4" 2 16384 65536 262144 1048576
echo "== supplementary: float sum at 80 ranks, 1 trial (GCC 4.8.5 build, as P1's float points)"
scaling_point float 80 20 "$H4" 1 65536 262144
echo "== control: native MPI chunked like HEAR's pipeline (no encryption), 80 ranks"
chunked_point int 80 20 "$H4" 2 65536 262144 1048576
echo "== synchronous HEAR + chunked-native control at the 2-node points (P1 measured only pipelined HEAR)"
for ppn in 1 2 4 10 20; do
    sync_point int $((2*ppn)) $ppn "$H2" 2
    chunked_point int $((2*ppn)) $ppn "$H2" 1 65536 262144 1048576
done

# Fig 9 + diagnostic live in a separate file, read only when the job gets here, so the
# libhear builds they use (jobs/tail_builds.txt) can still be chosen after this job starts.
source "$ROOT/jobs/perf4_tail.sh"
echo "== $(stamp) perf4 done"
