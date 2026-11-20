#!/bin/bash
# Build the §5.3.1 security experiment for 80 ranks (4 nodes x 20 cores).
# The authors' driver hard-codes NUM_CORES=95 for 96 ranks (the last rank idles).
# With NUM_CORES = number of ranks, all 80 ranks work and the 2^23 plaintext
# mantissas are split into 80 contiguous ranges with no gap or overlap.
# Nothing else in the experiment changes.  Run after build.sh.
ROOT="$(cd "$(dirname "$0")" && pwd)"
. /opt/apps/intel/compilers_and_libraries_2018.2.199/linux/mpi/intel64/bin/mpivars.sh
set -euo pipefail
cd "$ROOT/libhear"
sed -i 's/int NUM_CORES=95;/int NUM_CORES=80;/' tests/security/security.cpp
grep -n "NUM_CORES=" tests/security/security.cpp
make clean > /dev/null && make security > "$ROOT/build/make_security80.log" 2>&1
mv security "$ROOT/build/bin/security_80"
git checkout -q tests/security/security.cpp && make clean > /dev/null
ls -la "$ROOT/build/bin/security_80"
