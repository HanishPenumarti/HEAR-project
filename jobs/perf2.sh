#!/bin/bash
# P1 (2 nodes): Fig 4 latency breakdown, Fig 6 block size, Fig 7/8 PPN scaling,
# end-to-end correctness (DCHECK).  Mirrors the authors' batch_*.sh scripts with
# Piz Daint's 36 cores/node replaced by our 20.
ROOT="$1"; source "$ROOT/jobs/common.sh"; source "$ROOT/jobs/osu_lib.sh"
export I_MPI_FABRICS=shm:dapl          # fastest RDMA fabric in the probe
OUT="$RES/perf"; mkdir -p "$OUT"; chmod 777 "$OUT" 2>/dev/null
exec > "$OUT/perf2_$JOBNUM.log" 2>&1
H2=$(hosts_csv 2)
echo "== $(stamp) job $PBS_JOBID on ${NODES[*]} fabric=$I_MPI_FABRICS"

echo "== Fig 4: critical path, 2 ranks (1/node), 8 and 16 B int sum, 5 trials x 100k iters"
D="$OUT/logs_critical_path"
for msg in 8 16; do for t in 1 2 3 4 5; do
    HENV=(-genv LD_PRELOAD "$LIB/libhear_critical_path_baseline.so")
    osu_run "$D/critical_path.baseline.$msg.$t.log" 2 1 "$H2" "$BIN/osu_allreduce_int" -m $msg:$msg -f -i 100000
    HENV=(-genv LD_PRELOAD "$LIB/libhear_critical_path_naive.so")
    osu_run "$D/critical_path.naive.$msg.$t.log" 2 1 "$H2" "$BIN/osu_allreduce_int" -m $msg:$msg -f -i 100000
    HENV=(-genv LD_PRELOAD "$LIB/libhear_critical_path_mpool.so" -genv HEAR_ENABLE_AESNI 1)
    osu_run "$D/critical_path.optimized.$msg.$t.log" 2 1 "$H2" "$BIN/osu_allreduce_int" -m $msg:$msg -f -i 100000
done; done

echo "== end-to-end correctness: DCHECK libhear asserts memcmp(HEAR result, plain MPI result), int sum"
D="$OUT/logs_dcheck"
for n in 2 40; do
    ppn=$((n/2))
    HENV=(-genv LD_PRELOAD "$LIB/libhear_dcheck_sync.so" -genv HEAR_ENABLE_AESNI 1)
    osu_run "$D/dcheck_sync.$n.log" $n $ppn "$H2" "$BIN/osu_allreduce_int" -m 4:16777216 -i 20 -x 2
    HENV=(-genv LD_PRELOAD "$LIB/libhear_dcheck_pipelined.so" -genv HEAR_ENABLE_AESNI 1 -genv HEAR_PIPELINING_BLOCK_SIZE 65536 -genv HEAR_MPOOL_SBUF_LEN 2097152)
    osu_run "$D/dcheck_pipelined.$n.log" $n $ppn "$H2" "$BIN/osu_allreduce_int" -m 4:16777216 -i 20 -x 2
done

echo "== Fig 6: block size sweep, 40 ranks (20/node), 16 MiB int sum, 2 trials x $LARGE_ITERS iters"
D="$OUT/logs_block_size"; N=40; msg=16777216
for t in 1 2; do
    native;              osu_run "$D/block_size.baseline.$N.$msg.$t.log"   $N 20 "$H2" "$BIN/osu_allreduce_int" -m $msg:$msg -f -i $LARGE_ITERS
    hear_sync_big $msg;  osu_run "$D/block_size.mpool_only.$N.$msg.$t.log" $N 20 "$H2" "$BIN/osu_allreduce_int" -m $msg:$msg -f -i $LARGE_ITERS
    for bs in 1024 2048 4096 8192 16384 32768 65536 131072 262144 524288 1048576; do
        hear_pipe $bs $msg; osu_run "$D/block_size.$N.$bs.$msg.$t.log" $N 20 "$H2" "$BIN/osu_allreduce_int" -m $msg:$msg -f -i $LARGE_ITERS
    done
done

# Block sizes (elements): the paper's 65536 plus neighbours; the probe suggested larger
# blocks win at full PPN on this network, so 262144 and 1048576 are included too.
echo "== Fig 7/8: PPN scaling on 2 nodes, int sum (paper's figure), 2 trials"
for ppn in 1 2 4 10 20; do scaling_point int $((2*ppn)) $ppn "$H2" 2 16384 65536 262144 1048576; done

echo "== supplementary: PPN scaling, float sum, 1 trial"
for ppn in 1 2 4 10 20; do scaling_point float $((2*ppn)) $ppn "$H2" 1 65536 262144; done

echo "== $(stamp) perf2 done"
