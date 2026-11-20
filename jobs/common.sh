# Sourced by every job body.  Sets up Intel MPI and helpers.
# Expects ROOT (absolute hear_repro path) to be set by the caller.
. /opt/apps/intel/compilers_and_libraries_2018.2.199/linux/mpi/intel64/bin/mpivars.sh
umask 022
BIN="$ROOT/build/bin"
LIB="$ROOT/build/lib"
RES="$ROOT/results"
JOBNUM="${PBS_JOBID%%.*}"
# Unique hosts of this allocation, in PBS order
NODES=($(awk '!seen[$0]++' "$PBS_NODEFILE"))
hosts_csv() { local n=$1; local IFS=,; echo "${NODES[*]:0:$n}"; }
stamp() { date '+%F %T'; }
# Fabric: chosen from the probe job (see results/probe); override with I_MPI_FABRICS env.
export I_MPI_FABRICS="${I_MPI_FABRICS:-shm:ofa}"
# Pin one rank per physical core, compact within a node (Intel MPI default domain=core)
export I_MPI_PIN=1
