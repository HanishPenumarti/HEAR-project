"""Parse HEAR experiment logs (ours or the authors' logs.sc23) into tidy CSVs.

Usage: python parse_logs.py <log_root> <out_dir> <label>
  <log_root> contains logs_critical_path/, logs_block_size/, logs_allreduce_*_scaling/,
  logs_single_core_tput/, logs_dnn/ (ours) or dnn/ (authors').
Metrics follow the authors' postprocess_synthetic_perf.py:
  throughput per rank [GB/s] = msg_bytes / avg_latency_us * 1e-3
"""
import os
import re
import sys
from pathlib import Path

import pandas as pd


def osu_row(path):
    """Last OSU result line: size avg min max iters -> dict (None if missing)."""
    rows = [l.split() for l in Path(path).read_text(errors="replace").splitlines()
            if re.match(r"^\d+\s+[\d.]+\s+[\d.]+\s+[\d.]+\s+\d+\s*$", l)]
    if not rows:
        return None
    size, avg, mn, mx, it = rows[-1]
    size, avg, mn, mx = int(size), float(avg), float(mn), float(mx)
    return dict(msgsize=size, avg_lat=avg, min_lat=mn, max_lat=mx, iters=int(it),
                avg_tput=size / avg * 1e-3, min_tput=size / mx * 1e-3, max_tput=size / mn * 1e-3)


def critical_path(root):
    out = []
    for p in sorted(Path(root, "logs_critical_path").glob("critical_path.*.log")):
        _, mode, msg, trial, _ = p.name.split(".")
        vals = {}
        for line in p.read_text(errors="replace").splitlines():
            m = re.match(r"^(comm|mmalloc|mfree|encrypt|decrypt)=(\d+)", line.strip())
            if m:
                vals[m.group(1)] = int(m.group(2))
        r = osu_row(p) or {}
        out.append(dict(mode=mode, msgsize=int(msg), trial=int(trial),
                        malloc=vals.get("mmalloc", 0), encrypt=vals.get("encrypt", 0),
                        comm=vals.get("comm", 0), decrypt=vals.get("decrypt", 0),
                        free=vals.get("mfree", 0), osu_avg_lat=r.get("avg_lat")))
    return pd.DataFrame(out)


def block_size(root):
    out = []
    for p in sorted(Path(root, "logs_block_size").glob("block_size.*.log")):
        parts = p.name.split(".")[1:-1]
        if parts[0] in ("baseline", "mpool_only"):
            mode, nranks, msg, trial = parts
            bs = 0
        else:
            nranks, bs, msg, trial = parts
            mode = "optimized"
        r = osu_row(p)
        if r:
            out.append(dict(mode=mode, nranks=int(nranks), block_size=int(bs),
                            trial=int(trial), **r))
    return pd.DataFrame(out)


def scaling(root, dtype):
    out = []
    for p in sorted(Path(root, f"logs_allreduce_{dtype}_scaling").glob("osu_allreduce.*.log")):
        parts = p.name.split(".")[1:-1]
        if len(parts) == 4:
            mode, nranks, msg, trial = parts
            bs = 0
        else:
            mode, nranks, msg, bs, trial = parts
        r = osu_row(p)
        if r:
            out.append(dict(dtype=dtype, mode=mode, nranks=int(nranks), block_size=int(bs),
                            trial=int(trial), **r))
    return pd.DataFrame(out)


def async_diag(root):
    """logs_async/async.<variant>[.<block>].<trial>.log (our background-progress diagnostic)."""
    out = []
    for p in sorted(Path(root, "logs_async").glob("async.*.log")):
        parts = p.name.split(".")[1:-1]
        variant, trial = parts[0], parts[-1]
        bs = int(parts[1]) if len(parts) == 3 else 0
        r = osu_row(p)
        if r:
            out.append(dict(variant=variant, block_size=bs, trial=int(trial), **r))
    return pd.DataFrame(out)


def compilers(root):
    """compilertest_*.log: '<build> <dtype> <func> items=<n> encryption=<x> decryption=<y>'."""
    out = []
    for p in sorted(Path(root, "compilers").glob("compilertest_*.log")):
        for line in p.read_text(errors="replace").splitlines():
            m = re.match(r"^(\S+) (int|float) (\S+) items=(\d+) encryption=([\d.eE+-]+) decryption=([\d.eE+-]+)", line)
            if m:
                out.append(dict(build=m.group(1), dtype=m.group(2), func=m.group(3), items=int(m.group(4)),
                                encryption=float(m.group(5)), decryption=float(m.group(6))))
    return pd.DataFrame(out)


def single_core(root):
    out = []
    for p in sorted(Path(root, "logs_single_core_tput").glob("single_core_encr_tput*.log")):
        parts = p.name.split(".")
        dtype, op, func, nitems = parts[-5], parts[-4], parts[-3], parts[-2]
        bufsize = None
        for line in p.read_text(errors="replace").splitlines():
            if line.startswith("Buffer size:"):
                bufsize = int(line.split()[2])
            m = re.match(r"Avg (en|de)cryption throughput: ([\d.eE+-]+)", line)
            if m and bufsize:
                out.append(dict(dtype=dtype, op=op, func=func, bufsize=bufsize,
                                mode="encryption" if m.group(1) == "en" else "decryption",
                                tput=float(m.group(2))))
    return pd.DataFrame(out)


def dnn(root):
    out = []
    for d in ("logs_dnn", "dnn"):
        for p in sorted(Path(root, d).glob("*.log")):
            parts = p.name.split(".")
            app, mode = parts[0], parts[1]
            nranks = int(parts[2]) if len(parts) == 4 else None
            text = p.read_text(errors="replace")
            m = re.search(r"(?:per iteration|each iteration) = ([\d.]+) s", text)
            ws = re.search(r"world_size = (\d+)", text)
            if m:
                out.append(dict(model=app, mode=mode,
                                nranks=nranks or (int(ws.group(1)) if ws else None),
                                time_per_iteration=float(m.group(1))))
    return pd.DataFrame(out)


def main():
    root, outdir, label = sys.argv[1], sys.argv[2], sys.argv[3]
    os.makedirs(outdir, exist_ok=True)
    tables = {"critical_path": critical_path(root), "block_size": block_size(root),
              "allreduce_int_scaling": scaling(root, "int"),
              "allreduce_float_scaling": scaling(root, "float"),
              "single_core_tput": single_core(root), "dnn": dnn(root),
              "async_diag": async_diag(root), "compilers": compilers(root)}
    for name, df in tables.items():
        if len(df):
            df.insert(0, "source", label)
            df.to_csv(Path(outdir, f"{name}.csv"), index=False)
        print(f"{label:8s} {name:24s} {len(df):5d} rows")


if __name__ == "__main__":
    main()
