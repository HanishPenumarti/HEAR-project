"""Write the dashboard datasets (JSON {rows, meta}) from results.json + raw logs.

Usage: python export_datasets.py <data_dir> <out_dir>
  <data_dir>/results.json         from summarize.py
  <data_dir>/ours/correctness/    integer.log, hfloat.log (cluster job L)
  <data_dir>/ours/dcheck/         dcheck_*.log (cluster job P1)
Each file's meta carries the code that produced it (this script, summarize.py,
parse_logs.py), read from disk so that the published code is the code that ran.
"""
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
DATA, OUT = Path(sys.argv[1]), Path(sys.argv[2])
OUT.mkdir(parents=True, exist_ok=True)
R = json.loads((DATA / "results.json").read_text(encoding="utf-8"))

CODE = [{"label": n, "value": (HERE / n).read_text(encoding="utf-8"), "type": "code", "lang": "python"}
        for n in ("parse_logs.py", "summarize.py", "export_datasets.py")]
PAPER_IN = ("Paper: the authors' raw logs (artifacts/logs.sc23.tar.gz) and accuracy CSVs "
            "in github.com/spcl/libhear at commit 88f114f; Piz Daint, 36 cores/node, "
            "Aries 100 Gb/s, Cray MPICH.")
OURS_IN = ("Ours: logs from PBS jobs on our cluster (2x Xeon E5-2630 v4, 20 cores/node, "
           "40 Gb/s QDR InfiniBand, Intel MPI 2018u2, GCC 4.8.5), at most 4 nodes.")


META = [{"label": "Input", "value": PAPER_IN + "\n" + OURS_IN}, *CODE]
TABLES = {}   # every table also goes into one combined file, hear_results.json


def write(name, rows, extra_meta=()):
    meta = [META[0], *extra_meta, *CODE]
    (OUT / f"{name}.json").write_text(json.dumps({"rows": rows, "meta": meta}, indent=1, ensure_ascii=False), encoding="utf-8")
    TABLES[name] = rows
    print(f"{name:12s} {len(rows):4d} rows")


def r3(x, nd=4):
    return None if x is None or x != x else float(f"{x:.{nd}g}")


def bytes_label(b):
    if b is None:
        return None
    return f"{b // 1048576} MiB" if b >= 1048576 else f"{b // 1024} KiB" if b >= 1024 else f"{b} B"


SRC = {"paper": "Paper", "ours": "Ours"}

# ---- precision (Fig 3) -------------------------------------------------------------
TYPE = {"native": "Native", "Native": "Native", "HEAR0": "HEAR γ=2", "HEAR1": "HEAR γ=1",
        "HEAR2": "HEAR γ=0", "HEAR": "HEAR"}
rows, match = [], []
for op, per in R["precision"].items():
    for fp, e in per.items():
        for src in ("paper", "ours"):
            for t, s in (e.get(src) or {}).items():
                rows.append({"source": SRC[src], "op": op, "precision": fp, "variant": TYPE[t],
                             "n": s["n"], "q1": r3(s["q1"]), "median": r3(s["median"]),
                             "q3": r3(s["q3"])})
        if "identical" in e:
            match.append({"op": op, "precision": fp, "rows_paper": e["rows_paper"],
                          "rows_ours": e["rows_ours"], "differing_rows": e["differing_rows"],
                          "identical": "yes" if e["identical"] else "no"})
write("precision", rows)
write("prec_match", match)

# ---- security (§5.3.1) -----------------------------------------------------------
def sci(v):
    m, e = f"{v:.2e}".split("e")
    return f"{m} × 10" + str(int(e)).translate(str.maketrans("-0123456789", "⁻⁰¹²³⁴⁵⁶⁷⁸⁹"))


sec = []
for src in ("paper", "ours"):
    s = R["security"].get(src)
    if s:
        row = {"source": SRC[src], "min": r3(s["min"], 3), "max": r3(s["max"], 3),
               "avg": r3(s["avg"], 3), "uniform": r3(s["uniform"], 3)}
        row.update({f"{k}_label": sci(row[k]) for k in ("min", "max", "avg", "uniform")})
        sec.append(row)
paper_s = sec[0]
if len(sec) == 1:
    sec[0]["status"] = "published"
    sec.append({"source": "Ours", "status": "running"})
else:
    sec[0]["status"] = "published"
    same = all(abs(sec[1][k] - paper_s[k]) <= 0.006e-7 for k in ("min", "max", "avg"))
    sec[1]["status"] = "matches paper" if same else "differs"
write("security", sec)

# ---- correctness (§6) ---------------------------------------------------------------
corr = [{"check": "Paper: float encrypt/decrypt round trip", "source": "Paper", "scope": "10 M values",
         "result": "avg rel. error 1.3e-07", "passed": "yes"},
        {"check": "Paper: integer sum vs reference MPI (memcmp)", "source": "Paper",
         "scope": "MPI_Allreduce", "result": "identical", "passed": "yes"}]
cdir = DATA / "ours" / "correctness"
il, hl = cdir / "integer.log", cdir / "hfloat.log"
if il.exists():
    ok = "integer_correctness exit=0" in il.read_text(encoding="utf-8", errors="replace")
    corr.append({"check": "Integer encrypt-sum-decrypt (assertions)", "source": "Ours",
                 "scope": "10,000 x 10,000 sums", "result": "no assertion failed" if ok else "FAILED",
                 "passed": "yes" if ok else "no"})
if hl.exists():
    t = hl.read_text(encoding="utf-8", errors="replace")
    errs = [float(x) for x in re.findall(r"^Error: ([-\d.eE+]+)", t, re.M)]
    ok = "hfloat_correctness exit=0" in t and errs
    mean_abs = sum(abs(e) for e in errs) / len(errs) if errs else None
    corr.append({"check": "Float encrypt/decrypt round trip", "source": "Ours",
                 "scope": f"{len(errs)} x 1 M values",
                 "result": f"avg rel. error {mean_abs:.2g}" if mean_abs is not None else "no output",
                 "passed": "yes" if ok else "no", "avg_rel_error": r3(mean_abs, 3)})
for p in sorted((DATA / "ours" / "dcheck").glob("dcheck_*.log")):
    kind, n = p.stem.split(".")[0].split("_")[1], int(p.stem.split(".")[1])
    t = p.read_text(errors="replace")
    sizes = re.findall(r"^(\d+)\s+[\d.]+\s*$", t, re.M)
    ok = len(sizes) > 0 and "Assertion" not in t and "BAD TERMINATION" not in t
    corr.append({"check": f"HEAR vs plain MPI_Allreduce, memcmp ({'pipelined' if kind == 'pipelined' else 'synchronous'})",
                 "source": "Ours", "scope": f"{n} ranks, {len(sizes)} sizes 4 B-16 MiB",
                 "result": "identical" if ok else "MISMATCH", "passed": "yes" if ok else "no"})
write("correctness", corr)

# ---- Fig 4 latency breakdown ---------------------------------------------------------
VAR4 = {"baseline": "Native MPI", "naive": "HEAR with SHA1 PRF", "optimized": "HEAR with AES-NI PRF"}
b4 = []
for src in ("paper", "ours"):
    for mode, v in (R["fig4"].get(src) or {}).items():
        b4.append({"source": SRC[src], "variant": VAR4[mode], "mem_alloc": round(v["malloc"]),
                   "encrypt": round(v["encrypt"]), "comm": round(v["comm"]),
                   "decrypt": round(v["decrypt"]), "mem_free": round(v["free"]),
                   "total": round(v["total"]), "overhead_pct": round(v["overhead_pct"], 1),
                   "latency_us": r3(v.get("osu_avg_lat_us"), 3)})
write("breakdown", b4)

# ---- Fig 5 single-core throughput ------------------------------------------------------
PRF = {"naive": "Unvectorized SHA1", "sha1sse2": "SHA1 (SSE2)", "sha1avx2": "SHA1 (AVX2)",
       "aesni_unroll": "AES-NI (compiler-vectorized)", "aesni": "AES-NI (hand-tuned SSE2)"}
ORDER = ["naive", "sha1sse2", "sha1avx2", "aesni_unroll", "aesni"]
f5 = []
for src in ("paper", "ours"):
    for d in R["fig5"].get(src) or []:
        if d["mean"] is None:
            continue
        f5.append({"source": SRC[src], "dtype": d["dtype"], "prf": PRF[d["func"]],
                   "order": ORDER.index(d["func"]), "mode": d["mode"],
                   "mean_gbs": r3(d["mean"], 3), "std_gbs": r3(d["std"], 3),
                   "at_8MiB_gbs": r3(d["at_8MiB"], 3)})
write("encryption", f5)

# ---- Fig 6 block size -------------------------------------------------------------------
f6 = []
for src in ("paper", "ours"):
    d = R["fig6"].get(src)
    if not d:
        continue
    f6.append({"source": SRC[src], "nranks": d["nranks"], "variant": "Synchronous HEAR",
               "block_bytes": None, "block_label": "whole message",
               "pct_of_native": round(d["sync_pct"], 1) if d["sync_pct"] == d["sync_pct"] else None,
               "tput_rank_gbs": r3(d["sync_tput_rank"], 3), "is_best": "no"})
    best = max((b["pct"] for b in d["blocks"]), default=None)
    for b in d["blocks"]:
        f6.append({"source": SRC[src], "nranks": d["nranks"], "variant": "Pipelined HEAR",
                   "block_bytes": b["block_bytes"], "block_label": bytes_label(b["block_bytes"]),
                   "pct_of_native": round(b["pct"], 1), "tput_rank_gbs": r3(b["tput_rank"], 3),
                   "is_best": "yes" if b["pct"] == best else "no"})
write("blocksize", f6)

# ---- Fig 7/8 scaling ----------------------------------------------------------------------
sc = []
for src in ("paper", "ours"):
    for dt in ("int", "float"):
        for r in R["fig7_8"].get(src, {}).get(dt) or []:
            sc.append({"source": SRC[src], "dtype": dt, "nranks": r["nranks"], "nodes": r["nodes"],
                       "ppn": r["ppn"], "native_gbs_node": r3(r.get("native_node_tput"), 3),
                       "hear_gbs_node": r3(r.get("hear_node_tput_65536"), 3),
                       "hear_pct": r3(r.get("pct_65536"), 3),
                       "best_block_bytes": r.get("best_block_bytes"),
                       "best_block_label": ("synchronous" if r.get("best_block_bytes") == 0
                                            else bytes_label(r.get("best_block_bytes"))),
                       "sync_gbs_node": r3(r.get("sync_node_tput"), 3),
                       "sync_pct": r3(r.get("pct_sync"), 3),
                       "chunked_native_pct": r3(r.get("pct_chunked_best"), 3),
                       "best_vs_best_native_pct": r3(r.get("pct_best_vs_best_native"), 3),
                       "hear_best_gbs_node": r3(r.get("hear_node_tput_best"), 3),
                       "best_pct": r3(r.get("pct_best"), 3),
                       "lat_native_us": r3(r.get("lat16_native_us"), 3),
                       "lat_hear_us": r3(r.get("lat16_hear_us"), 3),
                       "lat_overhead_pct": r3(r.get("lat16_overhead_pct"), 3)})
write("scaling", sc)

# ---- Fig 9 DNN proxies -----------------------------------------------------------------------
MODEL = {"resnet": "ResNet-152", "dlrm": "DLRM", "cosmoflow": "CosmoFlow", "gpt3": "GPT-3"}
BUILD = {"clang13": "clang 13", "gcc9": "GCC 9.3", "gcc48": "GCC 4.8.5", "icc": "Intel icpc 18",
         "build": "GCC 4.8.5", "build_gcc9": "GCC 9.3", "build_icc": "Intel icpc 18", "paper": "clang 13"}
PRIMARY_BUILD = "GCC 9.3"      # our libhear build for the float path (best vectorizer we have)
dn = []
for src in ("paper", "ours"):
    for d in R["fig9"].get(src) or []:
        dn.append({"source": SRC[src], "model": MODEL[d["model"]], "nranks": d["nranks"],
                   "build": BUILD.get(d["build"], d["build"]),
                   "native_s": r3(d["baseline_s"], 4), "hear_s": r3(d["hear_s"], 4),
                   "hear_pct": round(d["ratio_pct"], 1)})
write("dnn", dn)

# ---- compiler sensitivity of libhear's AES-NI routines (8 MiB buffers, one core) -----------
CV = {("int", "aesni"): "int · hand-tuned SSE2", ("int", "aesni_unroll"): "int · compiler-vectorized",
      ("float", "aesni_unroll"): "float · compiler-vectorized (libhear's float path)"}
comp = [{"compiler": BUILD.get(r["build"], r["build"]), "variant": CV[(r["dtype"], r["func"])],
         "order": list(CV).index((r["dtype"], r["func"])),
         "enc_gbs": r3(r.get("encryption"), 3), "dec_gbs": r3(r.get("decryption"), 3)}
        for r in R.get("compilers", []) if (r["dtype"], r["func"]) in CV]
write("compilers", comp)

# ---- diagnostic: background progress for pipelining (ours only) --------------------------------
AV = {"baseline": "Native MPI", "baseline_async": "Native MPI + progress threads",
      "sync": "Synchronous HEAR", "pipe": "Pipelined HEAR", "pipe_async": "Pipelined HEAR + progress threads"}
asy = [{"variant": AV.get(d["variant"], d["variant"]),
        "block_label": bytes_label(d["block_bytes"]) if d["block_bytes"] else "whole message",
        "block_bytes": d["block_bytes"] or None, "pct_of_native": round(d["pct_of_native"], 1),
        "tput_rank_gbs": r3(d["tput_rank"], 3), "trials": d["trials"]}
       for d in R.get("async_diag", [])]
write("async_diag", asy)

# ---- setup comparison -----------------------------------------------------------------------
write("setup", [
    {"aspect": "CPU", "paper": "2 x Xeon E5-2695 v4 (Broadwell), 2.1 GHz", "ours": "2 x Xeon E5-2630 v4 (Broadwell), 2.2 GHz, Turbo Boost off"},
    {"aspect": "Cores per node", "paper": "36", "ours": "20 (Hyper-Threading off)"},
    {"aspect": "Nodes used", "paper": "up to 32 (scaling), 48 (GPT-3)", "ours": "up to 4"},
    {"aspect": "Network", "paper": "Cray Aries, 100 Gb/s", "ours": "Mellanox Connect-IB, 40 Gb/s QDR InfiniBand (3.19 GB/s measured point-to-point)"},
    {"aspect": "MPI", "paper": "Cray MPICH 7.7.18", "ours": "Intel MPI 2018 Update 2, DAPL fabric"},
    {"aspect": "Compiler", "paper": "clang 13.0.1, -O3 -ffast-math -march=native", "ours": "GCC 4.8.5, same flags plus -std=c++11"},
    {"aspect": "Libraries", "paper": "OpenSSL 1.1.1, MPFR 4.1.0", "ours": "OpenSSL 1.0.2k, MPFR 4.1.0 (built from source)"},
    {"aspect": "Scheduler", "paper": "Slurm", "ours": "PBS Pro 14 (site submission wrapper)"},
])

# ---- scorecard: one row per result; each verdict comes from the explicit rule below ----------
def pick(rows, **kw):
    return next((r for r in rows if all(r.get(k) == v for k, v in kw.items())), None)


card = []


def add(result, where, paper, ours, status, verdict):
    card.append({"result": result, "where": where, "paper": paper, "ours": ours,
                 "status": status, "verdict": verdict})


# 1. Precision: exact if all six result files are identical to the authors'.
n_id = sum(m["identical"] == "yes" for m in match)
if len(match) < 6 or any(m["rows_ours"] < m["rows_paper"] for m in match):
    add("Float precision loss", "Fig 3", "6 result files", f"{n_id} of {len(match)} files identical so far", "pending", "Running")
else:
    st = "exact" if n_id == 6 else "differs"
    add("Float precision loss", "Fig 3", "6 result files", f"{n_id} of 6 files bit-identical", st,
        "Exact match" if st == "exact" else "Differs")

# 2. Security: exact if min, max and average likelihood equal the paper's to 3 significant digits.
o = sec[1] if len(sec) > 1 else {}
if "max" not in o:
    add("Security (MAP adversary)", "§5.3.1", f"max {paper_s['max_label']}", "running", "pending", "Running")
else:
    st = "exact" if o["status"] == "matches paper" else "differs"
    add("Security (MAP adversary)", "§5.3.1", f"max {paper_s['max_label']}, avg {paper_s['avg_label']}",
        f"max {o['max_label']}, avg {o['avg_label']}", st, "Exact match" if st == "exact" else "Differs")

# 3. Correctness: reproduced if every check we ran passed.
ours_c = [c for c in corr if c["source"] == "Ours"]
fl = pick(ours_c, check="Float encrypt/decrypt round trip")
ok_all = ours_c and all(c["passed"] == "yes" for c in ours_c)
add("Correctness", "§6", "lossless ints; float error 1.3e-07",
    f"{sum(c['passed'] == 'yes' for c in ours_c)} of {len(ours_c)} checks pass; float error {fl['avg_rel_error'] if fl else '—'}",
    "reproduced" if ok_all else "differs", "Reproduced" if ok_all else "Differs")

# 4. Encryption throughput: reproduced if the five integer PRF variants rank in the same order
#    and hand-tuned AES-NI is at least 10x faster than the best SHA1 variant in both runs.
def enc_rank(src):
    rs = [r for r in f5 if r["source"] == src and r["dtype"] == "int" and r["mode"] == "encryption"]
    return [r["prf"] for r in sorted(rs, key=lambda r: r["mean_gbs"])], {r["prf"]: r["mean_gbs"] for r in rs}


rp, vp = enc_rank("Paper")
ro, vo = enc_rank("Ours")
A, S = "AES-NI (hand-tuned SSE2)", "SHA1 (AVX2)"
if len(ro) < 5:
    add("Encryption speed per core", "Fig 5", f"AES-NI {vp.get(A)} GB/s", "running", "pending", "Running")
else:
    ok = rp == ro and vo[A] >= 10 * vo[S] and vp[A] >= 10 * vp[S]
    add("Encryption speed per core", "Fig 5", f"AES-NI {vp[A]} GB/s; SHA1 {vp[S]} GB/s",
        f"AES-NI {vo[A]} GB/s; SHA1 {vo[S]} GB/s", "reproduced" if ok else "partial",
        "Reproduced" if ok else "Partly")

# 5. Small-message latency: reproduced if AES-NI adds under 20% and SHA1 at least 3x as much.
def ovh(src, v):
    r = pick(b4, source=src, variant=v)
    return r["overhead_pct"] if r else None


pa, ps = ovh("Paper", "HEAR with AES-NI PRF"), ovh("Paper", "HEAR with SHA1 PRF")
oa, os_ = ovh("Ours", "HEAR with AES-NI PRF"), ovh("Ours", "HEAR with SHA1 PRF")
if oa is None:
    add("Latency overhead, 16 B", "Fig 4", f"+{pa}% (AES-NI), +{ps}% (SHA1)", "running", "pending", "Running")
else:
    ok = oa < 20 and os_ >= 3 * oa
    add("Latency overhead, 16 B", "Fig 4", f"+{pa}% (AES-NI), +{ps}% (SHA1)", f"+{oa}% (AES-NI), +{os_}% (SHA1)",
        "reproduced" if ok else "partial", "Reproduced" if ok else "Partly")

# 6. Block size: reproduced if the best pipelined block is an interior optimum and beats
#    synchronous HEAR by at least 2 points of native throughput.
def bs_summary(src):
    rs = [r for r in f6 if r["source"] == src]
    pipe = [r for r in rs if r["variant"] == "Pipelined HEAR"]
    sync = pick(rs, variant="Synchronous HEAR")
    best = pick(pipe, is_best="yes")
    return pipe, sync, best


pp, psync, pbest = bs_summary("Paper")
op, osync, obest = bs_summary("Ours")
if len(op) < 11:
    add("Pipelining block size", "Fig 6", f"best {pbest['block_label']} → {pbest['pct_of_native']}%", "running", "pending", "Running")
else:
    sizes = sorted(r["block_bytes"] for r in op)
    interior = sizes[0] < obest["block_bytes"] < sizes[-1]
    gain = obest["pct_of_native"] - osync["pct_of_native"]
    ok = interior and gain >= 2
    add("Pipelining block size", "Fig 6", f"best {pbest['block_label']} → {pbest['pct_of_native']}% (sync {psync['pct_of_native']}%)",
        f"best {obest['block_label']} → {obest['pct_of_native']}% (sync {osync['pct_of_native']}%)",
        "reproduced" if ok else "partial", "Reproduced" if ok else "Partly: little gain over synchronous")

# 7. Throughput scaling: reproduced (at our scale) if HEAR's best setting keeps at least 70% of
#    the best native throughput at every full-node configuration we could run (2 and 4 nodes).
#    "Best native" is Intel MPI's default or the same Allreduce chunked like HEAR's pipeline
#    without encryption (our control), whichever is faster; without the control, the default.
full = [r for r in sc if r["source"] == "Ours" and r["dtype"] == "int" and r["ppn"] == 20]
pfull = [r for r in sc if r["source"] == "Paper" and r["dtype"] == "int" and r["ppn"] == 36]
prange = f"{min(r['hear_pct'] for r in pfull):.0f}–{max(r['hear_pct'] for r in pfull):.0f}% of native, 2–32 nodes"
if len(full) < 2 or any(r["best_pct"] is None for r in full):
    add("Throughput scaling", "Fig 7", prange, "running", "pending", "Running")
else:
    fair = [r["best_vs_best_native_pct"] if r["best_vs_best_native_pct"] is not None else r["best_pct"] for r in full]
    full_sorted = sorted(full, key=lambda r: r["nodes"])
    txt = "; ".join(f"{r['nodes']} nodes: {r['best_pct']:.0f}% of default MPI"
                    + (f", {r['best_vs_best_native_pct']:.0f}% of chunked MPI" if r["best_vs_best_native_pct"] is not None else "")
                    for r in full_sorted)
    lo = min(fair)
    add("Throughput scaling", "Fig 7", prange, txt,
        "reproduced" if lo >= 70 else "partial", "Reproduced, up to 4 nodes" if lo >= 70 else "Partly")

# 8. Latency scaling: reproduced (at our scale) if HEAR's 16-byte overhead stays within the
#    paper's own spread (-21% to +14%) widened to +/-25% at every configuration we ran.
lat = [r for r in sc if r["source"] == "Ours" and r["dtype"] == "int" and r["lat_overhead_pct"] is not None]
plat = [r["lat_overhead_pct"] for r in sc if r["source"] == "Paper" and r["dtype"] == "int"]
if len(lat) < 6:
    add("Latency scaling", "Fig 8", f"{min(plat):+.0f}% to {max(plat):+.0f}%", "running", "pending", "Running")
else:
    vals = [r["lat_overhead_pct"] for r in lat]
    ok = all(-25 <= v <= 25 for v in vals)
    add("Latency scaling", "Fig 8", f"{min(plat):+.0f}% to {max(plat):+.0f}% (2–1152 ranks)",
        f"{min(vals):+.0f}% to {max(vals):+.0f}% (2–80 ranks)", "reproduced" if ok else "partial",
        "Reproduced, up to 4 nodes" if ok else "Partly: overhead above the paper's")

# 9. Training overhead: reproduced if each model's HEAR time is 100-150% of native and the
#    models rank the same way as in the paper (ResNet-152 highest).
ours80 = [r for r in dn if r["source"] == "Ours" and r["nranks"] == 80]
pref = [r for r in ours80 if r["build"] == PRIMARY_BUILD] or ours80
od = {r["model"]: r["hear_pct"] for r in pref}
pd_ = {r["model"]: r["hear_pct"] for r in dn if r["source"] == "Paper"}
if len(od) < 3:
    add("Deep-learning training overhead", "Fig 9", ", ".join(f"{k} {v}%" for k, v in pd_.items() if k != "GPT-3"), "running", "pending", "Running")
else:
    same_order = sorted(od, key=od.get) == sorted((k for k in pd_ if k in od), key=pd_.get)
    ok = all(100 <= v <= 150 for v in od.values()) and same_order
    add("Deep-learning training overhead", "Fig 9", ", ".join(f"{k} {pd_[k]}%" for k in od),
        ", ".join(f"{k} {v}%" for k, v in od.items()) + f" (80 ranks, {pref[0]['build']})", "reproduced" if ok else "partial",
        "Reproduced, at 80 ranks" if ok else "Partly")
write("scorecard", card)

stamp = datetime.now(timezone.utc).isoformat(timespec="seconds")
(OUT / "hear_results.json").write_text(json.dumps({"generated": stamp, "tables": TABLES, "meta": META},
                                                  ensure_ascii=False), encoding="utf-8")
(OUT / "_generated_at.txt").write_text(stamp)
print(f"hear_results.json: {len(TABLES)} tables, {(OUT / 'hear_results.json').stat().st_size} bytes")
