#!/bin/bash
# Probe job (2 nodes): environment, MPI fabric, link speed, libhear sanity.
ROOT="$1"; source "$ROOT/jobs/common.sh"
OUT="$RES/probe"; mkdir -p "$OUT"; chmod 777 "$OUT" 2>/dev/null
exec > "$OUT/probe_$JOBNUM.log" 2>&1
echo "== probe job $PBS_JOBID as $(whoami) on $(hostname) at $(stamp)"
echo "nodes: ${NODES[*]}"
H2=$(hosts_csv 2)

echo "== node facts"
for h in "${NODES[@]}"; do
  echo "--- $h"
  ssh -o BatchMode=yes "$h" 'lscpu | grep -E "Model name|^CPU\(s\)|Thread\(s\)|Socket\(s\)|NUMA node\(s\)|CPU max MHz"
    echo "aes=$(grep -c -w aes /proc/cpuinfo) avx2=$(grep -c -w avx2 /proc/cpuinfo)"
    echo "governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null) no_turbo=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null)"
    echo "memlock=$(ulimit -l)"; free -g | sed -n 2p
    for d in /sys/class/infiniband/*; do echo "$(basename $d) rate=$(cat $d/ports/1/rate) state=$(cat $d/ports/1/state)"; done
    [ -f /etc/dat.conf ] && echo "dat.conf entries: $(grep -v "^#" /etc/dat.conf | grep -c .)"'
done

echo "== shared-library check on compute node"
for b in "$BIN"/* "$LIB"/*.so; do
  if ldd "$b" | grep -q "not found"; then echo "MISSING in $b:"; ldd "$b" | grep "not found"; fi
done; echo "(ldd check done)"

echo "== quick single-core encryption (int aesni, 4 MiB buffer, 200 iters)"
"$BIN/encr_perf_test" 200 1048576 1 int sum aesni | grep -E "throughput"

echo "== fabric survey: 2 ranks (1/node), 16 MiB int allreduce, 50 iters"
best=""; bestlat=""
for fab in default shm:dapl shm:ofa shm:tmi shm:ofi tcp; do
  if [ "$fab" = default ]; then envfab=""; else envfab="-genv I_MPI_FABRICS $fab"; fi
  res=$( (unset I_MPI_FABRICS; timeout 120 mpirun -n 2 -ppn 1 -hosts "$H2" $envfab -genv I_MPI_DEBUG 5 \
          "$BIN/osu_allreduce_int" -m 16777216:16777216 -f -i 50) 2>&1 )
  mode=$(echo "$res" | grep -m1 -oE "MPI startup\(\): [a-z]+( and [a-z]+)? data transfer modes")
  lat=$(echo "$res" | awk '$1==16777216{print $2}')
  echo "--- fabric=$fab  -> ${mode:-?}  avg_lat_us=${lat:-FAILED}"
  [ -z "$lat" ] && echo "$res" | grep -iE "error|fail|abort" | head -3
  if [ -n "$lat" ] && [ "$fab" != default ] && { [ -z "$bestlat" ] || awk "BEGIN{exit !($lat < $bestlat)}"; }; then
    best=$fab; bestlat=$lat
  fi
done
echo "BEST_FABRIC=$best ($bestlat us)"
export I_MPI_FABRICS="$best"

echo "== point-to-point link characterisation (fabric $I_MPI_FABRICS)"
mpirun -n 2 -ppn 1 -hosts "$H2" "$BIN/osu_bw" -m 65536:16777216 | tail -9
mpirun -n 2 -ppn 1 -hosts "$H2" "$BIN/osu_latency" -m 0:64 | tail -8

echo "== libhear interception: critical-path variants print TSC cycles at MPI_Finalize"
for v in baseline naive mpool; do
  echo "--- $v"
  extra=""; [ "$v" = mpool ] && extra="-genv HEAR_ENABLE_AESNI 1"
  mpirun -n 2 -ppn 1 -hosts "$H2" -genv LD_PRELOAD "$LIB/libhear_critical_path_$v.so" $extra \
      "$BIN/osu_allreduce_int" -m 16:16 -f -i 20000 | grep -E "^16 |=[0-9]+"
done

echo "== end-to-end correctness smoke test (DCHECK asserts memcmp vs plain MPI), int sum 4B..16MiB"
mpirun -n 4 -ppn 2 -hosts "$H2" -genv LD_PRELOAD "$LIB/libhear_dcheck_sync.so" -genv HEAR_ENABLE_AESNI 1 \
    "$BIN/osu_allreduce_int" -m 4:16777216 -i 10 -x 2 > /dev/null; echo "dcheck_sync rc=$?"
mpirun -n 4 -ppn 2 -hosts "$H2" -genv LD_PRELOAD "$LIB/libhear_dcheck_pipelined.so" -genv HEAR_ENABLE_AESNI 1 \
    -genv HEAR_PIPELINING_BLOCK_SIZE 65536 -genv HEAR_MPOOL_SBUF_LEN 2097152 \
    "$BIN/osu_allreduce_int" -m 4:16777216 -i 10 -x 2 > /dev/null; echo "dcheck_pipelined rc=$?"

echo "== pipelining risk check: 16 MiB int allreduce, baseline vs sync HEAR vs pipelined HEAR"
for ppn in 1 20; do
  n=$((2*ppn))
  echo "--- $n ranks ($ppn per node)"
  run() { mpirun -n $n -ppn $ppn -hosts "$H2" "$@" "$BIN/osu_allreduce_int" -m 16777216:16777216 -f -i 40 -x 5 | awk '$1==16777216{print $2}'; }
  echo "baseline        avg_lat_us=$(run)"
  echo "hear_sync       avg_lat_us=$(run -genv LD_PRELOAD $LIB/libhear_release_mpool.so -genv HEAR_ENABLE_AESNI 1 -genv HEAR_MPOOL_SBUF_LEN 16777216)"
  for bs in 16384 65536 262144; do
    echo "hear_pipe bs=$bs avg_lat_us=$(run -genv LD_PRELOAD $LIB/libhear_release.so -genv HEAR_ENABLE_AESNI 1 -genv HEAR_PIPELINING_BLOCK_SIZE $bs -genv HEAR_MPOOL_SBUF_LEN 2097152)"
  done
  if [ $ppn = 1 ]; then
    echo "hear_pipe bs=65536 +I_MPI_ASYNC_PROGRESS avg_lat_us=$(run -genv LD_PRELOAD $LIB/libhear_release.so -genv HEAR_ENABLE_AESNI 1 -genv HEAR_PIPELINING_BLOCK_SIZE 65536 -genv HEAR_MPOOL_SBUF_LEN 2097152 -genv I_MPI_ASYNC_PROGRESS 1)"
    echo "hear_pipe bs=65536 +MPICH_ASYNC_PROGRESS avg_lat_us=$(run -genv LD_PRELOAD $LIB/libhear_release.so -genv HEAR_ENABLE_AESNI 1 -genv HEAR_PIPELINING_BLOCK_SIZE 65536 -genv HEAR_MPOOL_SBUF_LEN 2097152 -genv MPICH_ASYNC_PROGRESS 1)"
  fi
done
echo "== probe done at $(stamp)"
