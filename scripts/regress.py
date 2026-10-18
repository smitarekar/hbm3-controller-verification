#!/usr/bin/env python3
"""Run every test across seeds, summarize pass/fail, merge coverage.

A run passes when UVM reports zero UVM_ERROR/UVM_FATAL, the scoreboard
reports zero mismatches, and the device model reports zero JEDEC
violations. SVA failures print through $error and are counted too.
"""
import argparse
import concurrent.futures as cf
import os
import re
import subprocess
import sys

TESTS = [
    "hbm_smoke_test", "hbm_rand_test", "hbm_stream_test", "hbm_conflict_test",
    "hbm_hazard_test", "hbm_wdrain_test", "hbm_starve_test", "hbm_refresh_test",
    "hbm_ecc_test", "hbm_strobe_test", "hbm_backpressure_test", "hbm_full_test",
]


def run(binary, test, seed, outdir):
    log = os.path.join(outdir, "logs", f"{test}_s{seed}.log")
    dat = os.path.join(outdir, "cov", f"{test}_s{seed}.dat")
    cmd = [binary, f"+UVM_TESTNAME={test}", f"+verilator+seed+{seed}",
           "+verilator+error+limit+50", f"+verilator+coverage+file+{dat}",
           "+UVM_NO_RELNOTES"]
    with open(log, "w") as f:
        p = subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT, timeout=3600)
    text = open(log, errors="replace").read()

    def count(pat):
        m = re.search(pat, text)
        return int(m.group(1)) if m else -1

    uvm_err = count(r"UVM_ERROR :\s+(\d+)")
    uvm_fat = count(r"UVM_FATAL :\s+(\d+)")
    sva = len(re.findall(r"%Error: .*Assertion failed", text)) + text.count("[hbm3_pc_model]")
    model = 0
    m = re.search(r"device model flagged (\d+)", text)
    if m:
        model = int(m.group(1))
    sb = re.search(r"\[SB\] (reads: .*)", text)
    ok = (p.returncode == 0 and uvm_err == 0 and uvm_fat == 0 and sva == 0 and model == 0)
    return test, seed, ok, uvm_err, sva, model, (sb.group(1) if sb else "no scoreboard report")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", required=True)
    ap.add_argument("--seeds", nargs="+", type=int, default=[1, 2, 3])
    ap.add_argument("--tests", nargs="+", default=TESTS)
    ap.add_argument("--out", default="sim")
    ap.add_argument("-j", type=int, default=os.cpu_count() or 2)
    a = ap.parse_args()
    os.makedirs(os.path.join(a.out, "logs"), exist_ok=True)
    os.makedirs(os.path.join(a.out, "cov"), exist_ok=True)

    jobs = [(t, s) for t in a.tests for s in a.seeds]
    results = []
    with cf.ThreadPoolExecutor(max_workers=a.j) as ex:
        futs = [ex.submit(run, a.bin, t, s, a.out) for t, s in jobs]
        for fu in cf.as_completed(futs):
            r = fu.result()
            results.append(r)
            print(f"{'PASS' if r[2] else 'FAIL'}  {r[0]:<24} seed {r[1]}")

    results.sort()
    lines = ["| Test | Seed | Result | UVM errors | SVA/model | Scoreboard |",
             "|---|---:|---|---:|---:|---|"]
    for t, s, ok, ue, sva, model, sb in results:
        lines.append(f"| {t} | {s} | {'PASS' if ok else 'FAIL'} | {ue} | {sva + model} | {sb} |")
    npass = sum(r[2] for r in results)
    lines.append("")
    lines.append(f"{npass}/{len(results)} runs passed")
    summary = "\n".join(lines)
    with open(os.path.join(a.out, "regress_summary.md"), "w") as f:
        f.write(summary + "\n")
    print("\n" + summary + "\n")

    dats = [os.path.join(a.out, "cov", f"{t}_s{s}.dat") for t, s in jobs]
    subprocess.run([sys.executable, os.path.join(os.path.dirname(__file__), "cov_report.py"),
                    "--md", os.path.join(a.out, "coverage_summary.md")] + dats)
    return 0 if npass == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
