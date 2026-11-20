# Sourced by perf4.sh when it reaches this point (so it can be adjusted while the job runs).
# Fig 9 DNN proxies with the libhear builds in jobs/tail_builds.txt (first = primary), then
# optional parts in priority order, each only if enough of the 3 h walltime is left.
. /opt/apps/intel/compilers_and_libraries_2018.2.199/linux/bin/compilervars.sh intel64 >/dev/null 2>&1  # icpc runtime
TAIL_BUILDS=$(grep -v '^#' "$ROOT/jobs/tail_builds.txt" 2>/dev/null | xargs); TAIL_BUILDS=${TAIL_BUILDS:-build}
PRIMARY=${TAIL_BUILDS%% *}; OTHERS=${TAIL_BUILDS#"$PRIMARY"}
tag_of() { case "$1" in build) echo gcc48;; build_gcc9) echo gcc9;; build_icc) echo icc;; *) echo "${1#build_}";; esac; }
left() { echo $(( 10800 - SECONDS )); }                  # seconds of walltime left
DEFAULT_LIB="$LIB"
D="$OUT/logs_dnn"; mkdir -p "$D"
hear_dnn() { HENV=(-genv LD_PRELOAD "$1/libhear_release.so" -genv HEAR_ENABLE_AESNI 1 \
                   -genv HEAR_PIPELINING_BLOCK_SIZE 262144 -genv HEAR_MPOOL_SBUF_LEN 8388608); }
echo "== $(stamp) Fig 9: DNN proxies at 80 ranks, native + primary build $PRIMARY ($(left) s left)"
for app in cosmoflow dlrm resnet; do
    native; osu_run "$D/$app.baseline.80.log" 80 20 "$H4" "$BIN/$app"
    hear_dnn "$ROOT/$PRIMARY/lib"; osu_run "$D/$app.hear-$(tag_of $PRIMARY).80.log" 80 20 "$H4" "$BIN/$app"
    grep -h "per iteration\|each iteration" "$D/$app".*.80.log
done

if [ "$(left)" -gt 1800 ]; then
  echo "== $(stamp) diagnostic: background progress for pipelining, 2 nodes x 10 ranks, 16 MiB int ($(left) s left)"
  # Ranks on cores 0-9, Intel MPI progress threads pinned to the idle cores 10-19.
  LIB="$DEFAULT_LIB"; DA="$OUT/logs_async"; N=20; PPN=10; msg=16777216
  PIN=(-genv I_MPI_PIN_PROCESSOR_LIST 0-9)
  ASYNC=(-genv I_MPI_ASYNC_PROGRESS 1 -genv I_MPI_ASYNC_PROGRESS_PIN 10,11,12,13,14,15,16,17,18,19)
  t=1
  native;             HENV+=("${PIN[@]}"); osu_run "$DA/async.baseline.$t.log" $N $PPN "$H2" "$BIN/osu_allreduce_int" -m $msg:$msg -f -i $LARGE_ITERS
  native;             HENV+=("${PIN[@]}" "${ASYNC[@]}"); osu_run "$DA/async.baseline_async.$t.log" $N $PPN "$H2" "$BIN/osu_allreduce_int" -m $msg:$msg -f -i $LARGE_ITERS
  hear_sync_big $msg; HENV+=("${PIN[@]}"); osu_run "$DA/async.sync.$t.log" $N $PPN "$H2" "$BIN/osu_allreduce_int" -m $msg:$msg -f -i $LARGE_ITERS
  for bs in 65536 262144 1048576; do
      hear_pipe $bs 8388608; HENV+=("${PIN[@]}"); osu_run "$DA/async.pipe.$bs.$t.log" $N $PPN "$H2" "$BIN/osu_allreduce_int" -m $msg:$msg -f -i $LARGE_ITERS
      hear_pipe $bs 8388608; HENV+=("${PIN[@]}" "${ASYNC[@]}"); osu_run "$DA/async.pipe_async.$bs.$t.log" $N $PPN "$H2" "$BIN/osu_allreduce_int" -m $msg:$msg -f -i $LARGE_ITERS
  done
else echo "== skipped the progress diagnostic: $(left) s left"; fi

for b in $OTHERS; do
  if [ "$(left)" -gt 2700 ]; then
    echo "== $(stamp) Fig 9 with the $b build ($(left) s left)"
    for app in cosmoflow dlrm resnet; do
        hear_dnn "$ROOT/$b/lib"; osu_run "$D/$app.hear-$(tag_of $b).80.log" 80 20 "$H4" "$BIN/$app"
    done
  else echo "== skipped Fig 9 with $b: $(left) s left"; fi
done

if [ "$(left)" -gt 900 ]; then
  echo "== $(stamp) Fig 9 at 40 ranks (CosmoFlow, DLRM) with $PRIMARY ($(left) s left)"
  for app in cosmoflow dlrm; do
      native; osu_run "$D/$app.baseline.40.log" 40 20 "$H2" "$BIN/$app"
      hear_dnn "$ROOT/$PRIMARY/lib"; osu_run "$D/$app.hear-$(tag_of $PRIMARY).40.log" 40 20 "$H2" "$BIN/$app"
  done
fi
LIB="$DEFAULT_LIB"
