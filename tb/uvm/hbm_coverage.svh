// Functional coverage. Every covergroup uses "with function sample(...)"
// because Verilator 5.050 drops covergroups that read class members
// directly; passing the values in keeps them all live on that version.
//
// What is covered, and why it matters for a memory controller:
//   cg_axi      burst shapes, IDs and responses seen at the AXI port
//   cg_cmd      every command type reaching every bank group and bank
//   cg_spacing  back-to-back column commands landing exactly on tCCD_S,
//               tCCD_L, tRTW and tWTR (proves the scheduler is not just
//               legal but tight)
//   cg_page     how many column hits each ACT buys (row-buffer locality)
//   cg_sched    queue occupancy, write-drain mode changes, starvation
//               override, refresh debt, read-credit stalls, backpressure
class hbm_coverage extends uvm_component;
  `uvm_component_utils(hbm_coverage)

  `uvm_analysis_imp_decl(_cov_w)
  `uvm_analysis_imp_decl(_cov_r)
  `uvm_analysis_imp_decl(_cov_d)
  uvm_analysis_imp_cov_w #(axi_item, hbm_coverage) imp_w;
  uvm_analysis_imp_cov_r #(axi_item, hbm_coverage) imp_r;
  uvm_analysis_imp_cov_d #(dfi_item, hbm_coverage) imp_d;

  virtual hbm_phy_if phy;

  typedef enum int {
    SP_SAME_BG_AT_CCDL, SP_SAME_BG_SLACK,
    SP_DIFF_BG_AT_CCDS, SP_DIFF_BG_SLACK,
    SP_RTW_AT_MIN, SP_RTW_SLACK,
    SP_WTR_S_AT_MIN, SP_WTR_L_AT_MIN, SP_WTR_SLACK,
    SP_IDLE
  } spacing_e;

  typedef enum int {T_RD_RD, T_RD_WR, T_WR_RD, T_WR_WR} turn_e;

  // ---------------- covergroups ----------------
  covergroup cg_axi with function sample(bit is_wr, bit [7:0] len, bit [3:0] id, bit [1:0] resp);
    cp_dir:  coverpoint is_wr { bins rd = {0}; bins wr = {1}; }
    cp_len:  coverpoint len {
      bins single = {0};
      bins short_ = {[1:3]};
      bins med    = {[4:7]};
      bins long_  = {[8:15]};
      bins vlong  = {[16:255]};
    }
    // Explicit bins rather than ids[]: Verilator 5.050 folds array bins
    // into one, which would silently hide an ID that is never used.
    cp_id: coverpoint id {
      bins id0  = {0};
      bins id1  = {1};
      bins id2  = {2};
      bins id3  = {3};
      bins id4  = {4};
      bins id5  = {5};
      bins id6  = {6};
      bins id7  = {7};
      bins id8  = {8};
      bins id9  = {9};
      bins id10 = {10};
      bins id11 = {11};
      bins id12 = {12};
      bins id13 = {13};
      bins id14 = {14};
      bins id15 = {15};
    }
    cp_resp: coverpoint resp { bins okay = {0}; bins slverr = {2}; }
    x_dir_len:  cross cp_dir, cp_len;
    x_dir_resp: cross cp_dir, cp_resp;
  endgroup

  covergroup cg_cmd with function sample(int kind, bit [1:0] bg, bit [1:0] ba);
    // kind: 0 ACT 1 PRE 2 RD 3 WR
    cp_kind: coverpoint kind { bins act = {0}; bins pre = {1}; bins rd = {2}; bins wr = {3}; }
    cp_bg:   coverpoint bg { bins bg0 = {0}; bins bg1 = {1}; bins bg2 = {2}; bins bg3 = {3}; }
    cp_ba:   coverpoint ba { bins ba0 = {0}; bins ba1 = {1}; bins ba2 = {2}; bins ba3 = {3}; }
    x_kind_bank: cross cp_kind, cp_bg, cp_ba;
  endgroup

  covergroup cg_ref with function sample(bit [3:0] owed);
    cp_owed: coverpoint owed {
      bins opportunistic = {1};
      bins postponed     = {[2:7]};
      bins urgent        = {[8:9]};
    }
  endgroup

  covergroup cg_spacing with function sample(spacing_e sp, turn_e tn);
    cp_sp: coverpoint sp {
      bins same_bg_at_tccd_l = {SP_SAME_BG_AT_CCDL};
      bins same_bg_slack     = {SP_SAME_BG_SLACK};
      bins diff_bg_at_tccd_s = {SP_DIFF_BG_AT_CCDS};
      bins diff_bg_slack     = {SP_DIFF_BG_SLACK};
      bins rd_wr_at_trtw     = {SP_RTW_AT_MIN};
      bins rd_wr_slack       = {SP_RTW_SLACK};
      bins wr_rd_at_twtr_s   = {SP_WTR_S_AT_MIN};
      bins wr_rd_at_twtr_l   = {SP_WTR_L_AT_MIN};
      bins wr_rd_slack       = {SP_WTR_SLACK};
    }
    cp_turn: coverpoint tn {
      bins rd_rd = {T_RD_RD}; bins rd_wr = {T_RD_WR};
      bins wr_rd = {T_WR_RD}; bins wr_wr = {T_WR_WR};
    }
  endgroup

  covergroup cg_page with function sample(int hits);
    cp_hits: coverpoint hits {
      bins one        = {1};
      bins few        = {[2:3]};
      bins several    = {[4:15]};
      bins many       = {[16:31]};
      bins whole_page = {[32:$]};
    }
  endgroup

  covergroup cg_sched with function sample(bit [4:0] q, bit wmode, bit starve, bit refr,
                                            bit credit_ok, bit fe_stall);
    cp_q: coverpoint q {
      bins empty = {0};
      bins low   = {[1:4]};
      bins mid   = {[5:11]};
      bins high  = {[12:15]};
      bins full  = {16};
    }
    cp_mode: coverpoint wmode { bins rd_mode = {0}; bins wr_mode = {1}; }
    cp_wmode: coverpoint wmode {
      bins enter_drain = (0 => 1);
      bins exit_drain  = (1 => 0);
    }
    cp_starve: coverpoint starve { bins override = {1}; }
    cp_refr:   coverpoint refr   { bins draining = {1}; bins enter = (0 => 1); }
    cp_credit: coverpoint credit_ok { bins stalled = {0}; }
    cp_fe:     coverpoint fe_stall  { bins queue_backpressure = {1}; }
    x_q_mode:  cross cp_q, cp_mode;
  endgroup

  // ---------------- state for derived samples ----------------
  int     last_col_kind = -1;   // 2 rd, 3 wr
  longint last_col_t;
  bit [1:0] last_col_bg;
  int     hits_since_act [16];
  bit     bank_open [16];
  longint dcyc;

  localparam int T_CCD_S = 2, T_CCD_L = 4, RL = 14, WL = 6, T_BURST = 2,
                 T_WTR_S = 4, T_WTR_L = 8, T_RTW = RL + T_BURST + 2 - WL;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    imp_w = new("imp_w", this);
    imp_r = new("imp_r", this);
    imp_d = new("imp_d", this);
    cg_axi = new();
    cg_cmd = new();
    cg_ref = new();
    cg_spacing = new();
    cg_page = new();
    cg_sched = new();
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual hbm_phy_if)::get(this, "", "phy_vif", phy))
      `uvm_fatal("NOVIF", "phy_vif not set")
  endfunction

  function void write_cov_w(axi_item b);
    cg_axi.sample(1, b.len, b.id, b.resp[0]);
  endfunction

  function void write_cov_r(axi_item r);
    bit [1:0] worst = 0;
    foreach (r.resp[i]) if (r.resp[i] != 0) worst = r.resp[i];
    cg_axi.sample(0, r.len, r.id, worst);
  endfunction

  function void write_cov_d(dfi_item d);
    case (d.row_cmd)
      hbm_pkg::RCMD_ACT: begin
        cg_cmd.sample(0, d.row_bank[3:2], d.row_bank[1:0]);
        bank_open[d.row_bank] = 1;
        hits_since_act[d.row_bank] = 0;
      end
      hbm_pkg::RCMD_PRE: begin
        cg_cmd.sample(1, d.row_bank[3:2], d.row_bank[1:0]);
        if (hits_since_act[d.row_bank] > 0) cg_page.sample(hits_since_act[d.row_bank]);
        bank_open[d.row_bank] = 0;
      end
      // The PHY bus is one cycle behind the scheduler, so by now the debt
      // counter has already been decremented for this REF.
      hbm_pkg::RCMD_REF: cg_ref.sample(phy.ref_owed + 4'd1);
      default: ;
    endcase
    if (d.col_cmd != hbm_pkg::CCMD_NOP) begin
      int kind = (d.col_cmd == hbm_pkg::CCMD_RD) ? 2 : 3;
      cg_cmd.sample(kind, d.col_bank[3:2], d.col_bank[1:0]);
      hits_since_act[d.col_bank]++;
      if (last_col_kind != -1) begin
        longint gap = d.t - last_col_t;
        bit same_bg = (d.col_bank[3:2] == last_col_bg);
        spacing_e sp = SP_IDLE;
        turn_e tn;
        tn = turn_e'((last_col_kind == 3 ? 2 : 0) + (kind == 3 ? 1 : 0));
        if (gap <= 32) begin
          if (last_col_kind == kind) begin
            if (same_bg) sp = (gap == T_CCD_L) ? SP_SAME_BG_AT_CCDL : SP_SAME_BG_SLACK;
            else         sp = (gap == T_CCD_S) ? SP_DIFF_BG_AT_CCDS : SP_DIFF_BG_SLACK;
          end else if (last_col_kind == 2) begin
            sp = (gap == T_RTW) ? SP_RTW_AT_MIN : SP_RTW_SLACK;
          end else begin
            if (!same_bg && gap == WL + T_BURST + T_WTR_S) sp = SP_WTR_S_AT_MIN;
            else if (same_bg && gap == WL + T_BURST + T_WTR_L) sp = SP_WTR_L_AT_MIN;
            else sp = SP_WTR_SLACK;
          end
        end
        if (sp != SP_IDLE) cg_spacing.sample(sp, tn);
      end
      last_col_kind = kind;
      last_col_t    = d.t;
      last_col_bg   = d.col_bank[3:2];
    end
  endfunction

  task run_phase(uvm_phase phase);
    wait (phy.rst_n === 1'b1);
    forever begin
      @(negedge phy.clk);
      cg_sched.sample(phy.q_count, phy.in_write_mode, phy.starve, phy.in_refresh,
                      phy.rd_credit_ok, phy.req_valid && !phy.req_ready);
    end
  endtask

  function void report_phase(uvm_phase phase);
    `uvm_info("COV", $sformatf({"axi %0.1f%%  cmd %0.1f%%  refresh %0.1f%%  spacing %0.1f%%  ",
                                "page %0.1f%%  sched %0.1f%%"},
                               cg_axi.get_inst_coverage(), cg_cmd.get_inst_coverage(),
                               cg_ref.get_inst_coverage(), cg_spacing.get_inst_coverage(),
                               cg_page.get_inst_coverage(), cg_sched.get_inst_coverage()), UVM_NONE)
  endfunction
endclass
