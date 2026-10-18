// JEDEC timing and protocol assertions on the controller's PHY command
// buses. Bound into hbm3_ctrl from tb_top.
//
// Spacing rules are written as "after X, no Y for N-1 cycles" with
// consecutive repetition, so each one is a direct reading of the spec
// table rather than a counter comparison. The only auxiliary state is the
// bank-open table and the tFAW window, which SVA has no native form for.
//
// The matching cover properties prove the controller actually reaches
// each minimum spacing (an assertion that never meets its antecedent at
// the boundary proves nothing about efficiency).
module hbm_jedec_sva
  import hbm_pkg::*;
#(
  parameter int T_RCD   = 14,
  parameter int T_RP    = 14,
  parameter int T_RAS   = 33,
  parameter int T_RC    = 47,
  parameter int T_RRD_S = 4,
  parameter int T_RRD_L = 6,
  parameter int T_FAW   = 20,
  parameter int T_CCD_S = 2,
  parameter int T_CCD_L = 4,
  parameter int T_WTR_S = 4,
  parameter int T_WTR_L = 8,
  parameter int T_RTP   = 5,
  parameter int T_WR    = 16,
  parameter int T_RFC   = 160,
  parameter int T_REFI  = 1950,
  parameter int RL      = 14,
  parameter int WL      = 6,
  parameter int T_BURST = 2,
  parameter int T_RTW   = RL + T_BURST + 2 - WL
) (
  input logic       clk,
  input logic       rst_n,
  input rcmd_e      row_cmd,
  input logic [1:0] row_bg,
  input logic [1:0] row_ba,
  input ccmd_e      col_cmd,
  input logic [1:0] col_bg,
  input logic [1:0] col_ba,
  input logic       wrdata_en,
  input logic [3:0] ref_owed
);
  localparam int WR2PRE  = WL + T_BURST + T_WR;
  localparam int WR2RD_L = WL + T_BURST + T_WTR_L;
  localparam int WR2RD_S = WL + T_BURST + T_WTR_S;

  wire [3:0] rbank = {row_bg, row_ba};
  wire [3:0] cbank = {col_bg, col_ba};
  wire act = (row_cmd == RCMD_ACT);
  wire pre = (row_cmd == RCMD_PRE);
  wire rf  = (row_cmd == RCMD_REF);
  wire rd  = (col_cmd == CCMD_RD);
  wire wr  = (col_cmd == CCMD_WR);
  wire col = rd || wr;

  // ---------------- auxiliary state ----------------
  logic [15:0] open_q;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) open_q <= '0;
    else begin
      if (act) open_q[rbank] <= 1'b1;
      if (pre) open_q[rbank] <= 1'b0;
    end

  logic [T_FAW-1:0] act_win;   // ACTs in the last T_FAW cycles, this one included
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) act_win <= '0;
    else        act_win <= {act_win[T_FAW-2:0], act};

  int unsigned since_ref;
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n)  since_ref <= 0;
    else if (rf) since_ref <= 0;
    else         since_ref <= since_ref + 1;

  default clocking cb @(posedge clk); endclocking
  default disable iff (!rst_n);

  // ---------------- per bank ----------------
  for (genvar b = 0; b < 16; b++) begin : g_bank
    wire act_b = act && rbank == b;
    wire pre_b = pre && rbank == b;
    wire col_b = col && cbank == b;
    wire rd_b  = rd  && cbank == b;
    wire wr_b  = wr  && cbank == b;

    a_trcd: assert property (act_b |-> ##1 !col_b [*T_RCD-1])
      else $error("tRCD bank %0d", b);
    a_tras: assert property (act_b |-> ##1 !pre_b [*T_RAS-1])
      else $error("tRAS bank %0d", b);
    a_trc:  assert property (act_b |-> ##1 !act_b [*T_RC-1])
      else $error("tRC bank %0d", b);
    a_trp:  assert property (pre_b |-> ##1 !act_b [*T_RP-1])
      else $error("tRP bank %0d", b);
    a_trtp: assert property (rd_b  |-> ##1 !pre_b [*T_RTP-1])
      else $error("tRTP bank %0d", b);
    a_twr:  assert property (wr_b  |-> ##1 !pre_b [*WR2PRE-1])
      else $error("tWR bank %0d", b);
    a_col_open:  assert property (col_b |-> open_q[b])
      else $error("RD/WR to closed bank %0d", b);
    a_act_closed: assert property (act_b |-> !open_q[b])
      else $error("ACT to open bank %0d", b);
    a_pre_open:  assert property (pre_b |-> open_q[b])
      else $error("PRE to closed bank %0d", b);

    c_trcd_min: cover property (act_b ##T_RCD col_b);
  end

  // ---------------- per bank group ----------------
  for (genvar g = 0; g < 4; g++) begin : g_bg
    wire act_g = act && row_bg == g;
    wire col_g = col && col_bg == g;
    wire rd_g  = rd  && col_bg == g;
    wire wr_g  = wr  && col_bg == g;

    a_trrd_l: assert property (act_g |-> ##1 !act_g [*T_RRD_L-1])
      else $error("tRRD_L bg %0d", g);
    a_tccd_l: assert property (col_g |-> ##1 !col_g [*T_CCD_L-1])
      else $error("tCCD_L bg %0d", g);
    a_twtr_l: assert property (wr_g  |-> ##1 !rd_g [*WR2RD_L-1])
      else $error("tWTR_L bg %0d", g);

    c_tccd_l_min: cover property (col_g ##T_CCD_L col_g);
  end

  // ---------------- pseudo-channel ----------------
  a_trrd_s: assert property (act |-> ##1 !act [*T_RRD_S-1]) else $error("tRRD_S");
  a_tccd_s: assert property (col |-> ##1 !col [*T_CCD_S-1]) else $error("tCCD_S");
  a_twtr_s: assert property (wr  |-> ##1 !rd  [*WR2RD_S-1]) else $error("tWTR_S");
  a_trtw:   assert property (rd  |-> ##1 !wr  [*T_RTW-1])   else $error("tRTW");
  a_tfaw:   assert property ($countones(act_win) <= 4)      else $error("tFAW");
  a_trfc:   assert property (rf  |-> ##1 !(act || rf) [*T_RFC-1]) else $error("tRFC");
  a_ref_idle: assert property (rf |-> open_q == '0) else $error("REF with open banks");
  a_refi:   assert property (since_ref <= 9 * T_REFI) else $error("refresh postponed > 8");
  a_owed:   assert property (ref_owed <= 4'd9) else $error("refresh debt overflow");

  // Write data lands exactly WL cycles after each WR, and never otherwise.
  a_wl:        assert property (wr |-> ##WL wrdata_en) else $error("write data late");
  a_wdata_src: assert property (wrdata_en |-> $past(wr, WL)) else $error("spurious write data");

  // One row and one column command per cycle are legal; a column command
  // and a PRE to the same bank in the same cycle is not.
  a_same_bank: assert property (col && pre |-> cbank != rbank)
    else $error("PRE and RD/WR to one bank in one cycle");

  // ---------------- efficiency covers ----------------
  c_tccd_s_min: cover property (col ##T_CCD_S col);
  c_trrd_s_min: cover property (act ##T_RRD_S act);
  c_faw_full:   cover property ($countones(act_win) == 4);
  c_rtw_min:    cover property (rd ##T_RTW wr);
  c_wtr_s_min:  cover property (wr ##WR2RD_S rd);
  c_dual_issue: cover property (act && col);
  c_ref_urgent: cover property (ref_owed == 4'd8);
endmodule
