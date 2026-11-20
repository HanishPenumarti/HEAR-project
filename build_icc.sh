#!/bin/bash
# Rebuild the encryption-heavy pieces of libhear with the Intel C++ compiler 18.0.2
# (installed with Intel MPI). Same reason as build_gcc9.sh: the "compiler-vectorized"
# AES-NI routines depend on the compiler's vectorizer (the paper used clang 13).
# icpc uses the system GCC's libstdc++, so the libraries mix safely with GCC-built apps.
# Flags: icpc equivalents of the authors' -O3 -ffast-math -march=native.
ROOT="$(cd "$(dirname "$0")" && pwd)"
. /opt/apps/intel/compilers_and_libraries_2018.2.199/linux/bin/compilervars.sh intel64
. /opt/apps/intel/compilers_and_libraries_2018.2.199/linux/mpi/intel64/bin/mpivars.sh
set -euo pipefail
umask 022
BIN="$ROOT/build_icc/bin"; LIB="$ROOT/build_icc/lib"
mkdir -p "$BIN" "$LIB"
echo "compiler: $(icpc --version | head -1)"
FLAGS="-std=c++11 -O3 -xHost -fp-model fast=2 -lcrypto -lssl"
V=(CXX=icpc MPICXX=mpiicpc "RELEASE_FLAGS=$FLAGS" "AES_FLAGS=-D AESNI=1")
cd "$ROOT/libhear"
mk() { local t=$1; shift; make "$t" "$@" > "$ROOT/build_icc/make_$t.log" 2>&1 || { echo "make $t FAILED"; tail -30 "$ROOT/build_icc/make_$t.log"; exit 1; }; }
make clean >/dev/null
mk encr_perf_test "${V[@]}";   mv encr_perf_test "$BIN/";                     make clean >/dev/null
mk hear_release_aes "${V[@]}"; mv libhear.so "$LIB/libhear_release.so";       make clean >/dev/null
mk hear_mpool_only "${V[@]}";  mv libhear.so "$LIB/libhear_release_mpool.so"; make clean >/dev/null
mk hear_release_aes CXX=icpc MPICXX=mpiicpc "RELEASE_FLAGS=$FLAGS -D DCHECK=1" "AES_FLAGS=-D AESNI=1"
mv libhear.so "$LIB/libhear_dcheck_pipelined.so";                             make clean >/dev/null
ls -la "$BIN" "$LIB"
