// Reference-model scoreboard.
//
// The controller posts writes (B returns before data reaches DRAM) and
// reorders across addresses, so "the value at address A" depends on when
// you ask. For every 32-byte address the scoreboard keeps the history of
// writes with two timestamps: when the beat was accepted (tw) and when its
// burst's B arrived (tb). A read beat accepted at ta and returned at tr may
// legally return:
//   * the newest write with tb <= ta (it was acknowledged before the read
//     was issued, so the read must see it or something newer), or
//   * any write with tw < tr that was not yet acknowledged at ta (racing).
// Anything else is a bug. Error injection goes in as a pseudo-write: a
// single-bit flip keeps the old data and must read back corrected (and
// bump the CE counter); a double-bit flip must read back as SLVERR.
class hbm_scoreboard extends uvm_component;
  `uvm_component_utils(hbm_scoreboard)

  `uvm_analysis_imp_decl(_wbeat)
  `uvm_analysis_imp_decl(_wdone)
  `uvm_analysis_imp_decl(_rdone)
  `uvm_analysis_imp_decl(_dfi)

  uvm_analysis_imp_wbeat #(axi_wbeat, hbm_scoreboard) imp_wbeat;
  uvm_analysis_imp_wdone #(axi_item,  hbm_scoreboard) imp_wdone;
  uvm_analysis_imp_rdone #(axi_item,  hbm_scoreboard) imp_rdone;
  uvm_analysis_imp_dfi   #(dfi_item,  hbm_scoreboard) imp_dfi;

  hbm_cfg cfg;
  virtual hbm_phy_if phy;

  typedef enum int {K_DATA, K_INJ1, K_INJ2} rk_e;
  typedef struct {
    bit [255:0] data;
    longint     tw;
    longint     tb_fixed;   // used for injections; data writes read burst.t_done
    axi_item    burst;
    rk_e        kind;
  } rec_t;

  localparam longint INF = 64'h7FFF_FFFF_FFFF_FFFF;

  rec_t hist [bit [22:0]][$];

  int n_rd_bursts, n_rd_beats, n_wr_bursts, n_wr_beats, n_mismatch;
  int ce_expected, ue_expected, n_slverr_b;
  longint max_rd_lat, sum_rd_lat;
  int n_raced;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    imp_wbeat = new("imp_wbeat", this);
    imp_wdone = new("imp_wdone", this);
    imp_rdone = new("imp_rdone", this);
    imp_dfi   = new("imp_dfi", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(hbm_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("NOCFG", "cfg not set")
    if (!uvm_config_db#(virtual hbm_phy_if)::get(this, "", "phy_vif", phy))
      `uvm_fatal("NOVIF", "phy_vif not set")
  endfunction

  function longint tb_of(rec_t r);
    if (r.kind != K_DATA) return r.tb_fixed;
    return (r.burst.t_done == 0) ? INF : r.burst.t_done;
  endfunction

  // ---------------- writes ----------------
  function void write_wbeat(axi_wbeat wb);
    rec_t r;
    n_wr_beats++;
    if (!wb.full_strb) return;            // DUT drops partial beats
    r.data = wb.data; r.tw = wb.t; r.burst = wb.burst; r.kind = K_DATA; r.tb_fixed = 0;
    hist[wb.addr[27:5]].push_back(r);
    if (hist[wb.addr[27:5]].size() > 32) void'(hist[wb.addr[27:5]].pop_front());
  endfunction

  function void write_wdone(axi_item b);
    bit any_partial = 0;
    n_wr_bursts++;
    foreach (b.strb[i]) if (b.strb[i] != '1) any_partial = 1;
    if (b.resp[0] != (any_partial ? 2'b10 : 2'b00)) begin
      n_mismatch++;
      `uvm_error("SB", $sformatf("BRESP=%0b for %s (partial strobe=%0b)", b.resp[0],
                                 b.convert2string(), any_partial))
    end
    if (b.resp[0] == 2'b10) n_slverr_b++;
  endfunction

  // Called by the ECC sequence after tb_top confirms the flip.
  // Cycle count on the same negedge grid the monitors use.
  longint cyc;
  task run_phase(uvm_phase phase);
    wait (phy.rst_n === 1'b1);
    forever begin
      @(negedge phy.clk);
      cyc++;
    end
  endtask

  // True once the newest write to this address has its B.
  function bit write_acked(bit [27:0] addr);
    bit [22:0] k = addr[27:5];
    if (!hist.exists(k) || hist[k].size() == 0) return 0;
    return hist[k][$].kind == K_DATA && hist[k][$].burst.t_done != 0;
  endfunction

  function void note_injection(bit [27:0] addr, bit dbl);
    rec_t r, base;
    longint t = cyc;
    bit [22:0] k = addr[27:5];
    base.data = '0;
    if (hist.exists(k) && hist[k].size() != 0) base = hist[k][$];
    r.data = base.data; r.tw = t; r.tb_fixed = t; r.kind = dbl ? K_INJ2 : K_INJ1;
    hist[k].push_back(r);
  endfunction

  // ---------------- reads ----------------
  function void write_rdone(axi_item r);
    longint lat = r.t_done - r.t_req;
    n_rd_bursts++;
    sum_rd_lat += lat;
    if (lat > max_rd_lat) max_rd_lat = lat;
    if (lat > cfg.max_rd_latency)
      `uvm_error("SB", $sformatf("read latency %0d > %0d cycles: %s", lat,
                                 cfg.max_rd_latency, r.convert2string()))
    for (int i = 0; i <= int'(r.len); i++) check_beat(r, i);
  endfunction

  function void check_beat(axi_item r, int i);
    bit [27:0] a  = r.addr + 28'(i * 32);
    bit [22:0] k  = a[27:5];
    longint    ta = r.t_req, tr = r.beat_t[i];
    rec_t      cands [$];
    rec_t      base;
    bit        have_base = 0;
    bit        ok = 0;
    n_rd_beats++;

    base.data = '0; base.kind = K_DATA; base.tw = 0;
    if (hist.exists(k)) begin
      foreach (hist[k][j]) if (tb_of(hist[k][j]) <= ta) begin base = hist[k][j]; have_base = 1; end
      foreach (hist[k][j])
        if (tb_of(hist[k][j]) > ta && hist[k][j].tw < tr) cands.push_back(hist[k][j]);
    end
    cands.push_front(base);
    if (cands.size() > 1) n_raced++;

    if (r.resp[i] == 2'b10) begin
      foreach (cands[j]) if (cands[j].kind == K_INJ2) ok = 1;
      if (ok) ue_expected++;
    end else if (r.resp[i] == 2'b00) begin
      foreach (cands[j])
        if (!ok && cands[j].kind != K_INJ2 && cands[j].data == r.data[i]) begin
          ok = 1;
          if (cands[j].kind == K_INJ1) ce_expected++;
        end
    end
    if (!ok) begin
      n_mismatch++;
      `uvm_error("SB", $sformatf("%s beat %0d @%07h resp=%0b data=%h..: no legal value (%0d candidates, first %h..)",
                                 r.convert2string(), i, a, r.resp[i], r.data[i][255:224],
                                 cands.size(), cands[0].data[255:224]))
    end
  endfunction

  // DFI items are only counted here, to cross-check the DUT perf counters.
  int d_act, d_pre, d_ref, d_rd, d_wr;
  function void write_dfi(dfi_item d);
    if (d.row_cmd == hbm_pkg::RCMD_ACT) d_act++;
    if (d.row_cmd == hbm_pkg::RCMD_PRE) d_pre++;
    if (d.row_cmd == hbm_pkg::RCMD_REF) d_ref++;
    if (d.col_cmd == hbm_pkg::CCMD_RD)  d_rd++;
    if (d.col_cmd == hbm_pkg::CCMD_WR)  d_wr++;
  endfunction

  function void check_phase(uvm_phase phase);
    if (int'(phy.ecc_ce_cnt) != ce_expected)
      `uvm_error("SB", $sformatf("ECC CE counter %0d, expected %0d", phy.ecc_ce_cnt, ce_expected))
    if (int'(phy.ecc_ue_cnt) != ue_expected)
      `uvm_error("SB", $sformatf("ECC UE counter %0d, expected %0d", phy.ecc_ue_cnt, ue_expected))
    // PHY bus is registered one cycle after the counters update; by
    // check_phase the bus has been idle long enough for them to agree.
    if (int'(phy.perf_act) != d_act || int'(phy.perf_rd) != d_rd || int'(phy.perf_wr) != d_wr ||
        int'(phy.perf_pre) != d_pre || int'(phy.perf_ref) != d_ref)
      `uvm_error("SB", $sformatf("perf counters disagree with PHY bus: ACT %0d/%0d PRE %0d/%0d REF %0d/%0d RD %0d/%0d WR %0d/%0d",
                                 phy.perf_act, d_act, phy.perf_pre, d_pre, phy.perf_ref, d_ref,
                                 phy.perf_rd, d_rd, phy.perf_wr, d_wr))
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info("SB", $sformatf({"reads: %0d bursts / %0d beats checked (%0d raced a write), ",
                               "writes: %0d bursts / %0d beats, SLVERR B: %0d, ",
                               "ECC CE/UE expected: %0d/%0d, read latency avg %0.1f max %0d, mismatches: %0d"},
                              n_rd_bursts, n_rd_beats, n_raced, n_wr_bursts, n_wr_beats, n_slverr_b,
                              ce_expected, ue_expected,
                              n_rd_bursts ? real'(sum_rd_lat) / n_rd_bursts : 0.0, max_rd_lat,
                              n_mismatch), UVM_NONE)
  endfunction
endclass
