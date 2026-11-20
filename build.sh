#!/bin/bash
# Build every binary needed for the HEAR reproduction on the login node.
# Adapted from libhear/sourceme.sh for this cluster:
#   GCC 4.8.5 (no clang), Intel MPI 2018u2 (wrapper is mpicxx), OpenSSL 1.0.2k,
#   MPFR 3.1.1, PBS Pro.  Run from <workdir>/hear_repro:  bash build.sh
ROOT="$(cd "$(dirname "$0")" && pwd)"
. /opt/apps/intel/compilers_and_libraries_2018.2.199/linux/mpi/intel64/bin/mpivars.sh  # not set -u safe
set -euo pipefail
umask 022
BIN="$ROOT/build/bin"; LIB="$ROOT/build/lib"
mkdir -p "$BIN" "$LIB"

echo "== 0. MPFR 4.1.0 (paper's version; system has 3.1.1, which lacks mpfr_nrandom)"
DEPS="$ROOT/deps"
if [ ! -f "$DEPS/lib/libmpfr.so" ]; then
    cd "$ROOT/src_dl"
    [ -f mpfr-4.1.0.tar.gz ] || wget -q https://www.mpfr.org/mpfr-4.1.0/mpfr-4.1.0.tar.gz
    rm -rf mpfr-4.1.0 && tar xzf mpfr-4.1.0.tar.gz && cd mpfr-4.1.0
    ./configure --prefix="$DEPS" --with-gmp=/usr > "$ROOT/build/mpfr_configure.log" 2>&1
    make -j8 > "$ROOT/build/mpfr_make.log" 2>&1 && make install > "$ROOT/build/mpfr_install.log" 2>&1
fi
MPFR_FLAGS="-I$DEPS/include -L$DEPS/lib -Wl,-rpath,$DEPS/lib"

echo "== 1. patch libhear Makefile for GCC 4.8.5 + Intel MPI"
cd "$ROOT/libhear"
git checkout -q Makefile
# GCC 4.8.5 defaults to C++98 -> add -std=c++11; clang++ -> g++; mpic++ -> mpicxx;
# precision tests link against our MPFR 4.1.0 instead of the system 3.1.1
sed -i -e 's/^CXX = clang++/CXX = g++/' \
       -e 's/^MPICXX = mpic++/MPICXX = mpicxx/' \
       -e 's/^DEBUG_FLAGS = /DEBUG_FLAGS = -std=c++11 /' \
       -e 's/^RELEASE_FLAGS = /RELEASE_FLAGS = -std=c++11 /' \
       -e 's/ -lmpfr -lgmp/ $(MPFR_FLAGS) -lmpfr -lgmp/' Makefile
git diff Makefile > "$ROOT/build/makefile_changes.diff" || true

echo "== 2. OSU micro-benchmarks 7.0.1 (stock = MPI_FLOAT, authors' patch = MPI_INT)"
cd "$ROOT/src_dl"
rm -rf osu-micro-benchmarks-7.0.1
tar xzf osu-micro-benchmarks-7.0.1.tar.gz
cd osu-micro-benchmarks-7.0.1
./configure CC=mpicc CXX=mpicxx CFLAGS="-O2 -std=gnu99" > "$ROOT/build/osu_configure.log" 2>&1
cd c/mpi/collective
make osu_allreduce > "$ROOT/build/osu_make_float.log" 2>&1
cp osu_allreduce "$BIN/osu_allreduce_float"
rm -f osu_allreduce osu_allreduce.o
cp "$ROOT/libhear/osu_patch/osu_allreduce.c" ./
make osu_allreduce > "$ROOT/build/osu_make_int.log" 2>&1
cp osu_allreduce "$BIN/osu_allreduce_int"
cd ../pt2pt   # point-to-point tests, only to characterise the raw link
make osu_bw osu_latency > "$ROOT/build/osu_make_pt2pt.log" 2>&1
cp osu_bw osu_latency "$BIN/"

echo "== 3. DNN proxies"
cd "$ROOT/libhear/dnn-proxies"
for app in gpt3 dlrm cosmoflow; do mpicxx "./$app.cpp" -O3 -ffast-math -o "$BIN/$app"; done
mpicxx ./resnet152.cpp -O3 -ffast-math -o "$BIN/resnet"

echo "== 4. libhear variants + tests (make clean between, as in sourceme.sh)"
cd "$ROOT/libhear"
mk() { make "$@" > "$ROOT/build/make_$1.log" 2>&1 || { echo "make $1 FAILED"; tail -30 "$ROOT/build/make_$1.log"; exit 1; }; }
make clean >/dev/null
mk encr_perf_test;      mv encr_perf_test "$BIN/";                                   make clean >/dev/null
mk hear_release_aes;    mv libhear.so "$LIB/libhear_release.so";                     make clean >/dev/null
mk hear_mpool_only;     mv libhear.so "$LIB/libhear_release_mpool.so";               make clean >/dev/null
mk hear_baseline_tsc;   mv libhear.so "$LIB/libhear_critical_path_baseline.so";      make clean >/dev/null
mk hear_naive_tsc;      mv libhear.so "$LIB/libhear_critical_path_naive.so";         make clean >/dev/null
mk hear_mpool_only_tsc; mv libhear.so "$LIB/libhear_critical_path_mpool.so";         make clean >/dev/null
mk security;            mv security "$BIN/";                                         make clean >/dev/null
mk accuracy MPFR_FLAGS="$MPFR_FLAGS"; mv accuracy_addition accuracy_multiplication "$BIN/"; make clean >/dev/null
mk correctness;         mv hfloat_correctness integer_correctness "$BIN/";           make clean >/dev/null
# End-to-end correctness (paper §6): DCHECK builds compare every HEAR MPI_Allreduce
# result against a plain PMPI_Allreduce of the unencrypted data with memcmp (assert).
mk debug_aes;           mv libhear.so "$LIB/libhear_dcheck_sync.so";                 make clean >/dev/null
mk hear_release_aes RELEASE_FLAGS="-std=c++11 -O3 -ffast-math -march=native -lcrypto -lssl -D DCHECK=1"
mv libhear.so "$LIB/libhear_dcheck_pipelined.so";                                    make clean >/dev/null

echo "== 5. control library (ours): native MPI chunked like HEAR's pipeline, no encryption"
mpicc -std=gnu99 -O3 -fPIC -shared -Wall -o "$LIB/libchunk.so" "$ROOT/control/chunk.c"

echo "== done"
ls -la "$BIN" "$LIB"
