# Helpers for OSU/libhear runs. Source after common.sh.
# Set the HENV array (extra mpirun -genv args) before calling osu_run.
# Log names follow the authors' scripts so their post-processing logic applies.
HENV=()
osu_run() {   # osu_run <log> <nranks> <ppn> <hosts> <binary> [args...]
    local log=$1 n=$2 ppn=$3 hosts=$4; shift 4
    mkdir -p "$(dirname "$log")"
    echo "$(stamp) mpirun -n $n -ppn $ppn -hosts $hosts ${HENV[*]} $*" > "${log%.log}.cmd"
    timeout "${TMO:-2400}" mpirun -n "$n" -ppn "$ppn" -hosts "$hosts" "${HENV[@]}" "$@" > "$log" 2>&1
    local rc=$?
    local last; last=$(grep -E '^[0-9]+ ' "$log" | tail -1)
    printf '%s rc=%s %-58s %s\n' "$(date +%T)" "$rc" "$(basename "$log")" "$last"
}
# HEAR library environments
hear_small()     { HENV=(-genv LD_PRELOAD "$LIB/libhear_release_mpool.so" -genv HEAR_ENABLE_AESNI 1 "$@"); }
hear_sync_big()  { HENV=(-genv LD_PRELOAD "$LIB/libhear_release_mpool.so" -genv HEAR_ENABLE_AESNI 1 -genv HEAR_MPOOL_SBUF_LEN "$1"); }
hear_pipe()      { HENV=(-genv LD_PRELOAD "$LIB/libhear_release.so" -genv HEAR_ENABLE_AESNI 1 -genv HEAR_PIPELINING_BLOCK_SIZE "$1" -genv HEAR_MPOOL_SBUF_LEN "$2"); }
native()         { HENV=(); }

# Iterations: the paper uses 100k for 8/16 B and 1000 for 16 MiB. A 16 MiB allreduce
# is ~3.4x slower on our 40 Gb/s QDR link than on Aries, so 300 iterations here
# take about the same wall time as their 1000 and still give stable means.
LARGE_ITERS=${LARGE_ITERS:-300}

# One rank-count point of the Fig 7/8 scaling experiment (authors' batch_allreduce_*_scaling.sh)
#   scaling_point <dtype> <nranks> <ppn> <hosts> <trials> <block sizes...>
scaling_point() {
    local dtype=$1 n=$2 ppn=$3 hosts=$4 trials=$5; shift 5
    local D="$OUT/logs_allreduce_${dtype}_scaling" B="$BIN/osu_allreduce_${dtype}" t msg bs
    for msg in 8 16; do for t in $(seq "$trials"); do
        native; osu_run "$D/osu_allreduce.baseline.$n.$msg.$t.log" "$n" "$ppn" "$hosts" "$B" -m $msg:$msg -f -i 100000
    done; done
    for t in $(seq "$trials"); do
        native; osu_run "$D/osu_allreduce.baseline.$n.16777216.$t.log" "$n" "$ppn" "$hosts" "$B" -m 16777216:16777216 -f -i $LARGE_ITERS
    done
    for msg in 8 16; do for t in $(seq "$trials"); do
        hear_small; osu_run "$D/osu_allreduce.optimized.$n.$msg.$t.log" "$n" "$ppn" "$hosts" "$B" -m $msg:$msg -f -i 100000
    done; done
    for bs in "$@"; do for t in $(seq "$trials"); do
        hear_pipe "$bs" 8388608; osu_run "$D/osu_allreduce.optimized.$n.16777216.$bs.$t.log" "$n" "$ppn" "$hosts" "$B" -m 16777216:16777216 -f -i $LARGE_ITERS
    done; done
    [ "${WITH_SYNC:-0}" = 1 ] && sync_point "$dtype" "$n" "$ppn" "$hosts" "$trials"
}
# Control (our addition): native MPI chunked into the same blocks as HEAR's pipeline,
# with the same Iallreduce+Wait calls but no encryption (control/chunk.c).
chunked_point() {   # chunked_point <dtype> <nranks> <ppn> <hosts> <trials> <block sizes...>
    local dtype=$1 n=$2 ppn=$3 hosts=$4 trials=$5; shift 5
    local D="$OUT/logs_allreduce_${dtype}_scaling" B="$BIN/osu_allreduce_${dtype}" t bs
    for bs in "$@"; do for t in $(seq "$trials"); do
        HENV=(-genv LD_PRELOAD "$LIB/libchunk.so" -genv CHUNK_BLOCK_SIZE "$bs")
        osu_run "$D/osu_allreduce.chunked.$n.16777216.$bs.$t.log" "$n" "$ppn" "$hosts" "$B" -m 16777216:16777216 -f -i $LARGE_ITERS
    done; done
}
# Synchronous (non-pipelined) HEAR for 16 MiB: not in the paper's Fig 7, added because on
# Intel MPI 2018 the pipelined variant gets no background progress (see Fig 6).
sync_point() {
    local dtype=$1 n=$2 ppn=$3 hosts=$4 trials=$5 t
    local D="$OUT/logs_allreduce_${dtype}_scaling" B="$BIN/osu_allreduce_${dtype}"
    for t in $(seq "$trials"); do
        hear_sync_big 16777216; osu_run "$D/osu_allreduce.sync.$n.16777216.$t.log" "$n" "$ppn" "$hosts" "$B" -m 16777216:16777216 -f -i $LARGE_ITERS
    done
}
