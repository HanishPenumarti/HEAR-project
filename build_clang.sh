#!/bin/bash
# Rebuild the encryption-heavy pieces of libhear with clang 7.0.1 (the paper used clang 13).
# libhear's "compiler-vectorized" AES-NI routines rely on clang's SLP vectorizer; GCC 4.8.5,
# GCC 9.3 and icpc 18 all leave them 6-16x slower than the paper measured.
# Uses LLVM's prebuilt SLES 11.3 binary (runs on CentOS 7); only the compiler and its
# intrinsic headers are extracted, into deps/llvm7. clang uses the system GCC 4.8.5
# libstdc++, so the libraries mix safely with the GCC-built applications.
ROOT="$(cd "$(dirname "$0")" && pwd)"
. /opt/apps/intel/compilers_and_libraries_2018.2.199/linux/mpi/intel64/bin/mpivars.sh
set -euo pipefail
umask 022
LLVM="$ROOT/deps/llvm7"
if [ ! -x "$LLVM/bin/clang-7" ]; then
    mkdir -p "$LLVM" "$ROOT/src_dl"
    TB="$ROOT/src_dl/llvm7.tar.xz"
    [ -s "$TB" ] || wget -q -O "$TB" https://releases.llvm.org/7.0.1/clang+llvm-7.0.1-x86_64-linux-sles11.3.tar.xz
    tar xJf "$TB" -C "$LLVM" --strip-components=1 --wildcards \
        '*/bin/clang' '*/bin/clang++' '*/bin/clang-7' '*/lib/clang/7.0.1/include/*'
    rm -f "$TB"
fi
CLANG="$LLVM/bin/clang++"
echo "compiler: $($CLANG --version | head -1)"
BIN="$ROOT/build_clang/bin"; LIB="$ROOT/build_clang/lib"
mkdir -p "$BIN" "$LIB"
V=("CXX=$CLANG" "MPICXX=mpicxx -cxx=$CLANG")
cd "$ROOT/libhear"
mk() { local t=$1; shift; make "$t" "$@" > "$ROOT/build_clang/make_$t.log" 2>&1 || { echo "make $t FAILED"; tail -30 "$ROOT/build_clang/make_$t.log"; exit 1; }; }
make clean >/dev/null
mk encr_perf_test "${V[@]}";   mv encr_perf_test "$BIN/";                     make clean >/dev/null
mk hear_release_aes "${V[@]}"; mv libhear.so "$LIB/libhear_release.so";       make clean >/dev/null
mk hear_mpool_only "${V[@]}";  mv libhear.so "$LIB/libhear_release_mpool.so"; make clean >/dev/null
mk hear_release_aes "${V[@]}" RELEASE_FLAGS="-std=c++11 -O3 -ffast-math -march=native -lcrypto -lssl -D DCHECK=1"
mv libhear.so "$LIB/libhear_dcheck_pipelined.so";                             make clean >/dev/null
ls -la "$BIN" "$LIB"
