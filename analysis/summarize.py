"""Combine parsed paper + our CSVs into results.json (paper-vs-ours metrics).

Usage: python summarize.py <data_dir> <authors_repo_accuracy_dir> <out_json>
  <data_dir>/authors/*.csv and <data_dir>/ours/*.csv come from parse_logs.py;
  <data_dir>/ours/accuracy/*.csv and <data_dir>/ours/security/* come from the cluster.
Every metric is computed the way the authors' plotting scripts compute it.
"""
import json
import math
import sys
from pathlib import Path

import numpy as np
import pandas as pd

DATA, AUTH_ACC, OUT = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
PPN = {"paper": 36, "ours": 20}          # cores per node used for full-node runs


def load(src, name):
    p = DATA / ("authors" if src == "paper" else "ours") / f"{name}.csv"
    return pd.read_csv(p) if p.exists() else pd.DataFrame()


def clean(x):
    if isinstance(x, dict):
        return {k: clean(v) for k, v in x.items()}
    if isinstance(x, list):
        return [clean(v) for v in x]
    if isinstance(x, (np.floating, float)):
        return None if (math.isnan(x) or math.isinf(x)) else float(x)
    if isinstance(x, np.integer):
        return int(x)
    return x


res = {}

# ---------------- Fig 3: precision loss -------------------------------------------
def acc_stats(path):
    df = pd.read_csv(path)
    df["error"] = pd.to_numeric(df["error"], errors="coerce")
    df = df[df["error"] > 0]                      # authors drop zero errors (log axis)
    out = {}
    for t, g in df.groupby("type"):
        q = g["error"].quantile([0.25, 0.5, 0.75])
        out[t] = dict(n=len(g), q1=q[0.25], median=q[0.5], q3=q[0.75])
    return out


prec = {}
for op, suffix in (("addition", "addition_combined"), ("multiplication", "multiplication_new")):
    for bits, name in ((11, "FP16"), (24, "FP32"), (53, "FP64")):
        fname = f"{bits}_float_{suffix}.csv"
        a, o = AUTH_ACC / fname, DATA / "ours" / "accuracy" / fname
        entry = {"paper": acc_stats(a) if a.exists() else None,
                 "ours": acc_stats(o) if o.exists() else None}
        if a.exists() and o.exists():
            la = [l.rstrip("\r\n") for l in a.read_text().splitlines()]
            lo = [l.rstrip("\r\n") for l in o.read_text().splitlines()]
            entry["rows_paper"], entry["rows_ours"] = len(la) - 1, len(lo) - 1
            entry["identical"] = la == lo
            entry["differing_rows"] = sum(x != y for x, y in zip(la, lo)) + abs(len(la) - len(lo))
        prec.setdefault(op, {})[name] = entry
res["precision"] = prec

# ---------------- §5.3.1 security ---------------------------------------------------
sec = {"paper": {"min": 2.38e-7, "max": 3.58e-7, "avg": 3.57e-7, "uniform": 1.19e-7}}
tot = DATA / "ours" / "security" / "mantissas_total.csv"
if tot.exists():
    df = pd.read_csv(tot)                         # header Index,Key,Value; rows i,count
    k = df["Key"] / 2 ** 23
    sec["ours"] = {"min": k.min(), "max": k.max(), "avg": k.mean(), "uniform": 1 / 2 ** 23,
                   "n_ciphertexts": len(df)}
res["security"] = sec

# ---------------- Fig 4: critical path ----------------------------------------------
stages = ["malloc", "encrypt", "comm", "decrypt", "free"]
f4 = {}
for src in ("paper", "ours"):
    df = load(src, "critical_path")
    if df.empty:
        continue
    df = df[(df.msgsize == 16) & df["mode"].isin(["baseline", "naive", "optimized"])]
    g = df.groupby("mode")[stages].mean()
    rows = {}
    for mode, r in g.iterrows():
        total = r[stages].sum()
        rows[mode] = {**{s: r[s] for s in stages}, "total": total,
                      "overhead_pct": (total / r["comm"] - 1) * 100,
                      "trials": int((df["mode"] == mode).sum())}
    lat = df.groupby("mode")["osu_avg_lat"].mean() if "osu_avg_lat" in df else None
    if lat is not None:
        for mode in rows:
            rows[mode]["osu_avg_lat_us"] = lat.get(mode)
    f4[src] = rows
res["fig4"] = f4

# ---------------- Fig 5: single-core throughput -------------------------------------
f5 = {}
for src in ("paper", "ours"):
    df = load(src, "single_core_tput")
    if df.empty:
        continue
    g = df.groupby(["dtype", "func", "mode"])["tput"]
    f5[src] = [dict(dtype=d, func=f, mode=m, mean=s.mean(), std=s.std(),
                    max=s.max(), at_8MiB=s[df.loc[s.index, "bufsize"] == 8388608].mean())
               for (d, f, m), s in g]
res["fig5"] = f5

# ---------------- Fig 6: block size -------------------------------------------------
f6 = {}
for src in ("paper", "ours"):
    df = load(src, "block_size")
    if df.empty:
        continue
    df = df[df.msgsize == 16777216]
    n = df["nranks"].max()                       # full-node run (paper 72, ours 40)
    df = df[df.nranks == n]
    base = df[df["mode"] == "baseline"]["avg_tput"].mean()
    sync = df[df["mode"] == "mpool_only"]["avg_tput"].mean()
    opt = df[df["mode"] == "optimized"].groupby("block_size")["avg_tput"].mean()
    f6[src] = {"nranks": n, "baseline_tput_rank": base, "sync_tput_rank": sync,
               "sync_pct": sync / base * 100,
               "blocks": [{"block_bytes": int(b) * 4, "tput_rank": t, "pct": t / base * 100}
                          for b, t in opt.items()]}
    best = max(f6[src]["blocks"], key=lambda r: r["pct"]) if len(opt) else None
    f6[src]["best"] = best
res["fig6"] = f6

# ---------------- Fig 7 / 8: scaling --------------------------------------------------
def scaling(src, dtype):
    df = load(src, f"allreduce_{dtype}_scaling")
    if df.empty:
        return None
    full = PPN[src]
    rows = []
    for n in sorted(df["nranks"].unique()):
        d = df[df.nranks == n]
        ppn = n // 2 if n <= 2 * full else full
        nodes = n // ppn
        r = {"nranks": int(n), "ppn": int(ppn), "nodes": int(nodes)}
        big = d[d.msgsize == 16777216]
        b = big[big["mode"] == "baseline"]["avg_tput"].mean()
        r["native_node_tput"] = b * ppn
        hear = big[big["mode"] == "optimized"].groupby("block_size")["avg_tput"].mean()
        r["hear_by_block"] = {int(k) * 4: v * ppn for k, v in hear.items()}
        if 65536 in hear.index:
            r["hear_node_tput_65536"] = hear[65536] * ppn
            r["pct_65536"] = hear[65536] / b * 100
        sync = big[big["mode"] == "sync"]["avg_tput"]
        if len(sync):
            r["sync_node_tput"] = sync.mean() * ppn
            r["pct_sync"] = sync.mean() / b * 100
        if len(hear):
            # best HEAR configuration: any pipelined block, or synchronous (block 0) if faster
            best_t, best_bs = hear.max(), int(hear.idxmax()) * 4
            if len(sync) and sync.mean() > best_t:
                best_t, best_bs = sync.mean(), 0
            r["hear_node_tput_best"] = best_t * ppn
            r["best_block_bytes"] = best_bs
            r["pct_best"] = best_t / b * 100
            # control (ours): native MPI chunked like HEAR's pipeline, no encryption
            chunk = big[big["mode"] == "chunked"].groupby("block_size")["avg_tput"].mean()
            if len(chunk):
                r["chunked_by_block"] = {int(k) * 4: v * ppn for k, v in chunk.items()}
                r["pct_chunked_best"] = chunk.max() / b * 100
                r["chunked_best_block_bytes"] = int(chunk.idxmax()) * 4
                best_native = max(b, chunk.max())
                r["pct_best_vs_best_native"] = best_t / best_native * 100
                same = [k for k in hear.index if k in chunk.index]
                r["hear_vs_chunked_same_block"] = {int(k) * 4: hear[k] / chunk[k] * 100 for k in same}
        small = d[d.msgsize == 16]
        lb = small[small["mode"] == "baseline"]["avg_lat"]
        lh = small[small["mode"] == "optimized"]["avg_lat"]
        if len(lb) and len(lh):
            r["lat16_native_us"], r["lat16_hear_us"] = lb.mean(), lh.mean()
            r["lat16_overhead_pct"] = (lh.mean() / lb.mean() - 1) * 100
            r["lat16_native_min"], r["lat16_native_max"] = small[small["mode"] == "baseline"]["min_lat"].min(), small[small["mode"] == "baseline"]["max_lat"].max()
            r["lat16_hear_min"], r["lat16_hear_max"] = small[small["mode"] == "optimized"]["min_lat"].min(), small[small["mode"] == "optimized"]["max_lat"].max()
        rows.append(r)
    return rows


res["fig7_8"] = {src: {dt: scaling(src, dt) for dt in ("int", "float")} for src in ("paper", "ours")}

# ---------------- Fig 9: DNN proxies -------------------------------------------------
f9 = {}
for src in ("paper", "ours"):
    df = load(src, "dnn")
    if df.empty:
        continue
    out = []
    for (model, n), g in df.groupby(["model", "nranks"]):
        b = g[g["mode"] == "baseline"]["time_per_iteration"]
        # paper logs: mode "hear"; ours: "hear-<build>" (gcc48, gcc9, icc, ...)
        for mode in sorted(m for m in g["mode"].unique() if m.startswith("hear")):
            h = g[g["mode"] == mode]["time_per_iteration"]
            if len(b) and len(h):
                out.append({"model": model, "nranks": int(n), "build": mode.partition("-")[2] or "clang13",
                            "baseline_s": b.mean(), "hear_s": h.mean(), "ratio_pct": h.mean() / b.mean() * 100})
    f9[src] = out
res["fig9"] = f9

# ---------------- compiler sensitivity (ours, 8 MiB buffers) + paper's value at 8 MiB ------
cc = load("ours", "compilers")
if not cc.empty:
    rows = []
    cc = cc[cc["items"] == 2097152]
    for (b, dt, fn), g in cc.groupby(["build", "dtype", "func"]):
        rows.append({"build": b, "dtype": dt, "func": fn,
                     "encryption": g["encryption"].mean(), "decryption": g["decryption"].mean()})
    for d in res["fig5"].get("paper", []):
        if (d["dtype"], d["func"]) in {(r["dtype"], r["func"]) for r in rows} and d["mode"] in ("encryption", "decryption"):
            pr = next((r for r in rows if r["build"] == "paper" and r["dtype"] == d["dtype"] and r["func"] == d["func"]), None)
            if pr is None:
                pr = {"build": "paper", "dtype": d["dtype"], "func": d["func"]}
                rows.append(pr)
            pr[d["mode"]] = d["at_8MiB"]
    res["compilers"] = rows

# ---------------- diagnostic: background progress (ours only) ------------------------------
ad = load("ours", "async_diag")
if not ad.empty:
    base = ad[ad.variant == "baseline"]["avg_tput"].mean()
    out = []
    for (v, bs), g in ad.groupby(["variant", "block_size"]):
        out.append({"variant": v, "block_bytes": int(bs) * 4, "tput_rank": g["avg_tput"].mean(),
                    "pct_of_native": g["avg_tput"].mean() / base * 100, "trials": len(g)})
    res["async_diag"] = out

OUT.write_text(json.dumps(clean(res), indent=1))
print(f"wrote {OUT} ({OUT.stat().st_size} bytes)")
