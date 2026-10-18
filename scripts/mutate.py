#!/usr/bin/env python3
"""Mutation testing: does the environment catch realistic controller bugs?

Each mutation is a small source edit that mimics a bug a designer could
plausibly write. For each one this copies the design repo, applies the
edit, rebuilds the UVM bench against the copy, and runs a short list of
tests. A mutation is "killed" when any run fails; the report records the
first test that failed and which checker fired.

usage: mutate.py [--dut ../hbm3-controller] [--only NAME ...]
"""
import argparse
import concurrent.futures as cf
import os
import re
import shutil
import subprocess
import sys
import tempfile

MUTATIONS = [
    ("trcd_short", "rtl/hbm_timing.sv",
     "c = ld(b_col[b], T_RCD);", "c = ld(b_col[b], T_RCD - 1);",
     "tRCD one cycle short"),
    ("faw_ignored", "rtl/hbm_timing.sv",
     "act_ok[b] = (b_act[b] == 0) && (g_act[g] == 0) && (c_act == 0) && faw_free;",
     "act_ok[b] = (b_act[b] == 0) && (g_act[g] == 0) && (c_act == 0);",
     "tFAW window not enforced"),
    ("wtr_l_missing", "rtl/hbm_timing.sv",
     "if (is_wr && col_bg == g) r = ld(r + 1'b1, WR_TO_RD_L);", "",
     "same-bank-group write-to-read turnaround dropped"),
    ("rtw_missing", "rtl/hbm_timing.sv",
     "if (is_rd) w = ld(w + 1'b1, T_RTW);", "",
     "read-to-write bus turnaround dropped"),
    ("raw_hazard", "rtl/hbm_scheduler.sv",
     "if (e_bank[j] == e_bank[i] && e_row[j] == e_row[i] && e_col[j] == e_col[i])\n            hazard[i] = 1'b1;",
     "", "same-address ordering removed (posted writes now unsafe)"),
    ("id_order", "rtl/hbm_scheduler.sv",
     "if (!is_wr[i] && !is_wr[j] && e_id[j] == e_id[i])\n            hazard[i] = 1'b1;",
     "", "same-ID read ordering removed"),
    ("row_compare", "rtl/hbm_scheduler.sv",
     "hit[i]  = b_open[e_bank[i]] && (b_row[e_bank[i]] == e_row[i]);",
     "hit[i]  = b_open[e_bank[i]] && (b_row[e_bank[i]][3:0] == e_row[i][3:0]);",
     "row-hit compare checks only the low row bits"),
    ("no_credit", "rtl/hbm_scheduler.sv",
     "(rd_ok[e_bank[i]] && rd_credit_ok)", "(rd_ok[e_bank[i]])",
     "RD issued without a guaranteed read-buffer slot"),
    ("no_starve", "rtl/hbm_scheduler.sv",
     "starve = head_v && (e_wait[head_i] >= SW'(STARVE));", "starve = 1'b0;",
     "starvation override disabled"),
    ("ref_never_urgent", "rtl/hbm_refresh.sv",
     "assign ref_urgent  = (owed >= MAX_POSTPONE[3:0]);", "assign ref_urgent  = 1'b0;",
     "refresh never forced when the queue stays busy"),
    ("ref_with_open_bank", "rtl/hbm_scheduler.sv",
     "ref_go = ref_active && (b_open == '0) && ref_ok;", "ref_go = ref_active && ref_ok;",
     "REFab issued without closing every bank"),
    ("ecc_no_correct", "rtl/hbm_secded.sv",
     "        cw[s] = ~cw[s];\n", "",
     "decoder flags a single-bit error but does not flip it back"),
    ("wl_short", "rtl/hbm3_ctrl.sv",
     "dfi_wrdata_en <= wpipe_v[WL];\n      dfi_wrdata    <= wpipe_d[WL];",
     "dfi_wrdata_en <= wpipe_v[WL-1];\n      dfi_wrdata    <= wpipe_d[WL-1];",
     "write data one cycle early"),
    ("rlast_off", "rtl/hbm_axi_fe.sv",
     "assign req_last  = grant_w ? w_last_bt : (ar_left == 0);",
     "assign req_last  = grant_w ? w_last_bt : (ar_left == 1);",
     "RLAST on the second-to-last beat"),
    ("b_early", "rtl/hbm_axi_fe.sv",
     "wire w_done = (w_acc || w_drop) && w_last_bt;", "wire w_done = (w_acc || w_drop);",
     "B returned on every beat instead of once per burst"),
    ("strobe_ignored", "rtl/hbm_axi_fe.sv",
     "wire w_partial = (wstrb != '1);", "wire w_partial = 1'b0;",
     "partial strobes written as full beats with OKAY"),
]

TESTS = ["hbm_smoke_test", "hbm_hazard_test", "hbm_conflict_test", "hbm_rand_test",
         "hbm_ecc_test", "hbm_strobe_test", "hbm_starve_test", "hbm_backpressure_test",
         "hbm_refresh_test"]


def first_checker(log):
    pats = [
        (r"Assertion failed in \S*\.(a_\w+)", "SVA {}"),
        (r"\[hbm3_pc_model\][^:]*: (.*)", "device model: {}"),
        (r"UVM_ERROR \S+ @ \d+: \S+ \[SB\] (.{0,60})", "scoreboard: {}"),
        (r"UVM_ERROR \S+ @ \d+: \S+ \[AXI\] (.{0,60})", "AXI monitor: {}"),
        (r"UVM_ERROR \S+ @ \d+: \S+ \[TEST\] (.{0,60})", "test: {}"),
        (r"UVM_FATAL.*?\] (.{0,60})", "fatal: {}"),
    ]
    best = None
    for pat, fmt in pats:
        m = re.search(pat, log)
        if m and (best is None or m.start() < best[0]):
            best = (m.start(), fmt.format(m.group(1).strip()))
    return best[1] if best else "nonzero exit"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dut", default="../hbm3-controller")
    ap.add_argument("--only", nargs="*")
    ap.add_argument("--md", default="sim/mutation_report.md")
    ap.add_argument("-j", type=int, default=max(1, (os.cpu_count() or 2) // 3))
    a = ap.parse_args()
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    dut_src = os.path.abspath(a.dut)

    def one(m):
        name, f, old, new, desc = m
        tmp = tempfile.mkdtemp(prefix=f"mut_{name}_")
        try:
            dut = os.path.join(tmp, "hbm3-controller")
            shutil.copytree(dut_src, dut, ignore=shutil.ignore_patterns("sim"))
            path = os.path.join(dut, f)
            src = open(path).read()
            if src.count(old) != 1:
                return (name, desc, "pattern missing", "-")
            open(path, "w").write(src.replace(old, new))
            obj = os.path.join(tmp, "obj")
            b = subprocess.run(["make", "-s", "build", f"DUT_DIR={dut}", f"OBJ={obj}",
                                f"BIN={obj}/sim_uvm"], cwd=here,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            if b.returncode != 0:
                return (name, desc, "build failed", "-")
            for t in TESTS:
                p = subprocess.run([f"{obj}/sim_uvm", f"+UVM_TESTNAME={t}", "+verilator+seed+1",
                                    "+verilator+error+limit+5", "+UVM_NO_RELNOTES",
                                    f"+verilator+coverage+file+{tmp}/cov.dat"],
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                   errors="replace", timeout=1800)
                log = p.stdout
                errs = re.search(r"UVM_ERROR :\s+(\d+)", log)
                failed = (p.returncode != 0 or (errs and int(errs.group(1)) > 0) or
                          "Assertion failed" in log or "[hbm3_pc_model]" in log or
                          "device model flagged" in log or not errs)
                if failed:
                    return (name, desc, t, first_checker(log))
            return (name, desc, "SURVIVED", "-")
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    todo = [m for m in MUTATIONS if not a.only or m[0] in a.only]
    rows = []
    with cf.ThreadPoolExecutor(max_workers=a.j) as ex:
        for r in ex.map(one, todo):
            rows.append(r)
            print(f"{'SURVIVED' if r[2] == 'SURVIVED' else 'KILLED':<9} {r[0]:<20} {r[2]:<22} {r[3]}",
                  flush=True)

    killed = sum(1 for r in rows if r[2] not in ("SURVIVED", "build failed", "pattern missing"))
    lines = ["| Mutation | Planted bug | Caught by test | First checker to fire |",
             "|---|---|---|---|"]
    for n, d, t, c in rows:
        lines.append(f"| `{n}` | {d} | {t} | {c.replace('|', '/')} |")
    lines.append("")
    lines.append(f"{killed}/{len(rows)} mutations killed")
    os.makedirs(os.path.dirname(a.md), exist_ok=True)
    open(a.md, "w").write("\n".join(lines) + "\n")
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
