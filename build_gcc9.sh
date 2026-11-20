#!/bin/bash
# Rebuild the encryption-heavy pieces of libhear with GCC 9.3 (Red Hat devtoolset-9).
# Why: libhear's "compiler-vectorized" AES-NI routines (used for MPI_FLOAT, and as one
# Fig 5 variant) are scalar code that only becomes SIMD through the compiler's SLP
# vectorizer. The paper used clang 13; GCC 4.8.5 leaves them ~6-16x slower. Same
# Makefile, same flags; only the compiler changes. Output: build_gcc9/{bin,lib}.
ROOT="$(cd "$(dirname "$0")" && pwd)"
source /opt/rh/devtoolset-9/enable
. /opt/apps/intel/compilers_and_libraries_2018.2.199/linux/mpi/intel64/bin/mpivars.sh
set -euo pipefail
umask 022
BIN="$ROOT/build_gcc9/bin"; LIB="$ROOT/build_gcc9/lib"
mkdir -p "$BIN" "$LIB"
echo "compiler: $(g++ --version | head -1)"
cd "$ROOT/libhear"
mk() { make "$@" > "$ROOT/build_gcc9/make_$1.log" 2>&1 || { echo "make $1 FAILED"; tail -30 "$ROOT/build_gcc9/make_$1.log"; exit 1; }; }
make clean >/dev/null
mk encr_perf_test;   mv encr_perf_test "$BIN/";                       make clean >/dev/null
mk hear_release_aes; mv libhear.so "$LIB/libhear_release.so";         make clean >/dev/null
mk hear_mpool_only;  mv libhear.so "$LIB/libhear_release_mpool.so";   make clean >/dev/null
mk hear_release_aes RELEASE_FLAGS="-std=c++11 -O3 -ffast-math -march=native -lcrypto -lssl -D DCHECK=1"
mv libhear.so "$LIB/libhear_dcheck_pipelined.so";                     make clean >/dev/null
ls -la "$BIN" "$LIB"
