# HEAR reproduction on a 4-node InfiniBand cluster

Reproduces the results of *HEAR: Homomorphically Encrypted Allreduce* (Chrapek, Khalilov,
Hoefler, SC '23, [doi:10.1145/3581784.3607099](https://doi.org/10.1145/3581784.3607099)) with the
authors' code ([spcl/libhear](https://github.com/spcl/libhear), commit 88f114f) on a PBS cluster,
using at most 4 nodes. The paper PDF is not included; see the DOI. GPT-3 (48 nodes) is out of scope.

## Results

| Result | Paper | Ours | Verdict |
|---|---|---|---|
| Float precision (Fig 3) | 6 result files | all 6 bit-identical | Exact match |
| Security, MAP adversary (§5.3.1) | max 3.58e-7, avg 3.57e-7 | max 2.38e-7, avg 2.38e-7 | Differs (each count one lower; cause not yet known) |
| Correctness (§6) | lossless ints, float error 1.3e-7 | 6/6 checks pass, float error 1.3e-7 | Reproduced |
| Encryption speed per core (Fig 5) | AES-NI 10.5 GB/s | 7.5 GB/s (Turbo Boost off), same ranking | Reproduced |
| 16 B latency overhead (Fig 4) | +7.1% AES-NI, +77% SHA1 | +11.1%, +96.5% | Reproduced |
| Pipelining block size (Fig 6) | best 128 KiB | best 1 MiB | Reproduced |
| Latency scaling (Fig 8) | −21% to +13% | −9% to +16% (2–80 ranks) | Reproduced |
| Throughput scaling (Fig 7) | 74–86% of native | 69–90% of equally chunked native MPI | Partly |
| DL training overhead (Fig 9) | 111–131% | 141–187% (GCC 9.3 build, 80 ranks) | Partly |

Two findings explain most differences:

- **Chunking artifact.** On Intel MPI 2018, splitting a 16 MiB Allreduce into 1 MiB pieces is
  ~1.6x faster than the default Allreduce, so pipelined HEAR "beats" native MPI. `control/chunk.c`
  chunks native MPI the same way without encryption; HEAR against that control gives 69–90%.
- **Compiler sensitivity.** libhear's float encryption (and one integer variant) relies on the
  compiler's vectorizer: 4.6 GB/s with the paper's clang 13, at most 0.42 GB/s with GCC 4.8.5,
  GCC 9.3 or Intel icpc 18. This dominates our Fig 9 overheads.

`datasets/hear_results.json` has every number; `dashboard/index.html` renders them.

## Layout

| Path | What it is |
|---|---|
| `build.sh` | Builds everything on the login node: MPFR 4.1.0, OSU 7.0.1 (+ authors' int patch), DNN proxies, all libhear variants, tests, and our control library. Only toolchain changes to the authors' Makefile (GCC 4.8.5 + `-std=c++11`, `mpicxx`). |
| `build_security80.sh` | Builds the §5.3.1 security test for 80 ranks (`NUM_CORES=80`; nothing else changed). |
| `build_gcc9.sh`, `build_icc.sh` | Rebuild libhear's encryption-heavy pieces with GCC 9.3 (devtoolset-9) and Intel icpc 18. |
| `build_clang.sh` | **Not run.** Would fetch LLVM's prebuilt clang 7.0.1 into `deps/` to match the paper's compiler family. |
| `control/chunk.c` | **Our addition.** Splits `MPI_Allreduce` into blocks with the same `Iallreduce`+`Wait` calls as libhear's pipeline, without encryption. |
| `control/resnet152_short.cpp` | The authors' ResNet-152 proxy with 5+10 iterations instead of 100+100 (the full run exceeded 40 min per run at 80 ranks). |
| `jobs/*.pbs.in`, `jobs/*.sh` | PBS jobs. `submit.sh` fills in absolute paths. `probe` = environment check; `perf2` = Figs 4, 6, 7/8 at 2 nodes + memcmp correctness; `local` = Fig 3 precision + unit tests; `fig5`/`fig5b` = Fig 5; `compilertest` = AES-NI speed per compiler; `perf4` (+ `perf4_tail.sh`, `tail_builds.txt`) = 4-node scaling, synchronous HEAR, chunked control, Fig 9, progress-thread diagnostic; `perf_dnn2` = ResNet-152 and GCC 4.8.5 DNN runs; `security` = §5.3.1. |
| `analysis/parse_logs.py` | Logs → tidy CSVs (works on our logs and on the authors' `logs.sc23`). |
| `analysis/summarize.py` | CSVs → `data/results.json`, using the formulas of the authors' plotting scripts. |
| `analysis/export_datasets.py` | `results.json` → dashboard tables, including the scorecard and its verdict rules. |
| `dashboard/index.html` | The results page (built for a claude.ai Data artifact; reads `hear_results.json`). |
| `data/authors/` | The paper's numbers, parsed from the authors' raw logs, plus their precision CSVs (`accuracy/`, BSD-3, see `LICENSE-libhear`). |
| `data/ours/` | Our raw logs and CSVs. The cluster username in log paths is replaced by `<user>`. |
| `datasets/` | Dashboard tables, one JSON per table plus the combined `hear_results.json`. |
| `tools/` | `remote.py` (SSH helper), `sync_up.sh`, `fetch_results.sh`. |

## Not in this repository

- **The paper PDF** — see the DOI above.
- **The cluster description and credentials** (`cluster.txt`, `credentials.txt`), which stay
  private. The hardware and software actually used are in the `setup` table of
  `datasets/hear_results.json`.

## Re-running

Requirements on your machine: Python 3 with `paramiko`, `pandas`, `numpy` (set `PYTHON` if the
interpreter isn't `python`), and bash with `tar` (Git Bash works on Windows).

1. Create `credentials.txt` **outside the repo**, in the folder that contains it (or point
   `HEAR_CREDENTIALS` at it):
   ```
   IP address: <login node IP>
   username: <your user>
   password: <your password>
   Directory to work in: <directory under your cluster home>
   ```
   `tools/remote.py` reads it, logs in with paramiko, runs everything inside that directory, and
   redacts IP, username and password from all output.
2. `bash tools/sync_up.sh` uploads the scripts. On the cluster, in `<workdir>/hear_repro`, clone
   libhear (`git clone https://github.com/spcl/libhear.git`, commit 88f114f), fetch OSU 7.0.1 into
   `src_dl/`, then run `bash build.sh` and `bash build_security80.sh` (and optionally
   `build_gcc9.sh`, `build_icc.sh`).
3. Submit: `bash jobs/submit.sh jobs/<name>.pbs.in`. Keep at most 4 nodes busy at once.
   Host names (`compute01`–`compute04`) and the Intel MPI path in `jobs/common.sh` are specific
   to our cluster.
4. `bash tools/fetch_results.sh` downloads the logs and regenerates `data/` and `datasets/`.

## Deviations from the paper

- Compiler/MPI: GCC 4.8.5 (GCC 9.3 for Fig 9) and Intel MPI 2018u2 instead of clang 13 and Cray MPICH; DAPL fabric.
- 20 cores/node instead of 36; node scaling stops at 4 nodes; DNN proxies at 80 ranks instead of 256.
- 16 MiB runs: 300 iterations instead of 1000 (each op is ~3.4x slower on 40 Gb/s QDR).
- ResNet-152 proxy: 10 timed iterations instead of 100.
- Fig 5's Python driver ported to bash (no python3 on compute nodes); same commands.
- Extra measurements not in the paper: synchronous HEAR at every scaling point, the chunked-MPI
  control, a progress-thread diagnostic (`I_MPI_ASYNC_PROGRESS`), and the compiler comparison.
