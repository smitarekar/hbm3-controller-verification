// Formal harness for hbm_timing.
//
// Claim: for every bank and every cycle, the engine's act_ok/pre_ok/
// rd_ok/wr_ok/ref_ok equal a reference built a completely different way,
// from "cycles since the last X" counters read straight off the JEDEC
// table. Equal in both directions: the engine never allows a command
// early (safety) and never blocks one that is already legal (no lost
// bandwidth).
//
// The command inputs are unconstrained except that an ACT is only issued
// when the engine allows it, because a 5th ACT inside tFAW has no defined
// meaning for the 4-slot window. Timing parameters are scaled down so the
// proof closes quickly; the structure is identical at any size.
module timing_equiv (
  input logic       clk,
  input logic       rst_n,
  input logic [1:0] row_cmd_i,
  input logic [1:0] row_bank,
  input logic [1:0] col_cmd_i,
  input logic [1:0] col_bank
);
  // 2 bank groups x 2 banks. Every per-bank and per-group path in the
  // engine is a generate over these widths, so this exercises all of them.
  localparam int BG_W = 1, BA_W = 1, NB = 4, NG = 2;
  localparam int T_RCD = 3, T_RP = 3, T_RAS = 5, T_RC = 8, T_RRD_S = 2, T_RRD_L = 3,
                 T_FAW = 7, T_CCD_S = 2, T_CCD_L = 3, T_WTR_S = 2, T_WTR_L = 3,
                 T_RTP = 2, T_WR = 3, T_RFC = 11, RL = 4, WL = 2, T_BURST = 1,
                 T_RTW = RL + T_BURST + 2 - WL;
  localparam int WR2PRE = WL + T_BURST + T_WR;
  localparam int WR2RD_L = WL + T_BURST + T_WTR_L;
  localparam int WR2RD_S = WL + T_BURST + T_WTR_S;
  localparam int SAT = 31;

  // RCMD: 0 NOP 1 ACT 2 PRE 3 REF ; CCMD: 0 NOP 1 RD 2 WR (3 treated as NOP)
  wire [1:0] row_cmd = row_cmd_i;
  wire [1:0] col_cmd = (col_cmd_i == 2'd3) ? 2'd0 : col_cmd_i;

  logic [NB-1:0] act_ok, pre_ok, rd_ok, wr_ok;
  logic        ref_ok;

  hbm_timing #(
    .BG_W(BG_W), .BA_W(BA_W),
    .T_RCD(T_RCD), .T_RP(T_RP), .T_RAS(T_RAS), .T_RC(T_RC), .T_RRD_S(T_RRD_S),
    .T_RRD_L(T_RRD_L), .T_FAW(T_FAW), .T_CCD_S(T_CCD_S), .T_CCD_L(T_CCD_L),
    .T_WTR_S(T_WTR_S), .T_WTR_L(T_WTR_L), .T_RTP(T_RTP), .T_WR(T_WR), .T_RFC(T_RFC),
    .RL(RL), .WL(WL), .T_BURST(T_BURST)
  ) dut (
    .clk, .rst_n,
    .row_cmd(hbm_pkg::rcmd_e'(row_cmd)), .row_bank,
    .col_cmd(hbm_pkg::ccmd_e'(col_cmd)), .col_bank,
    .act_ok, .pre_ok, .rd_ok, .wr_ok, .ref_ok
  );

  wire act = row_cmd == 2'd1, pre = row_cmd == 2'd2, rf = row_cmd == 2'd3;
  wire rd  = col_cmd == 2'd1, wr  = col_cmd == 2'd2;
  wire rbg = row_bank[1], cbg = col_bank[1];

  // ---------------- reference: cycles since each event ----------------
  logic [4:0] s_act [NB], s_pre [NB], s_rd [NB], s_wr [NB];
  logic [4:0] s_actg [NG], s_colg [NG], s_wrg [NG];
  logic [4:0] s_actc, s_col, s_rdc, s_wrc, s_ref;
  logic [T_FAW-2:0] acts;   // ACTs in the previous T_FAW-1 cycles

  function automatic logic [4:0] step(input logic [4:0] s, input logic ev);
    return ev ? 5'd1 : ((s == SAT[4:0]) ? s : s + 5'd1);
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int b = 0; b < NB; b++) begin
        s_act[b] <= SAT[4:0]; s_pre[b] <= SAT[4:0]; s_rd[b] <= SAT[4:0]; s_wr[b] <= SAT[4:0];
      end
      for (int g = 0; g < NG; g++) begin
        s_actg[g] <= SAT[4:0]; s_colg[g] <= SAT[4:0]; s_wrg[g] <= SAT[4:0];
      end
      s_actc <= SAT[4:0]; s_col <= SAT[4:0]; s_rdc <= SAT[4:0]; s_wrc <= SAT[4:0];
      s_ref  <= SAT[4:0];
      acts   <= '0;
    end else begin
      for (int b = 0; b < NB; b++) begin
        s_act[b] <= step(s_act[b], act && row_bank == b);
        s_pre[b] <= step(s_pre[b], pre && row_bank == b);
        s_rd[b]  <= step(s_rd[b],  rd  && col_bank == b);
        s_wr[b]  <= step(s_wr[b],  wr  && col_bank == b);
      end
      for (int g = 0; g < NG; g++) begin
        s_actg[g] <= step(s_actg[g], act && rbg == g);
        s_colg[g] <= step(s_colg[g], (rd || wr) && cbg == g);
        s_wrg[g]  <= step(s_wrg[g],  wr && cbg == g);
      end
      s_actc <= step(s_actc, act);
      s_col  <= step(s_col, rd || wr);
      s_rdc  <= step(s_rdc, rd);
      s_wrc  <= step(s_wrc, wr);
      s_ref  <= step(s_ref, rf);
      acts   <= {acts[T_FAW-3:0], act};
    end
  end

  function automatic int popc(input logic [T_FAW-2:0] v);
    int n = 0;
    for (int i = 0; i < T_FAW - 1; i++) n += v[i];
    return n;
  endfunction

  logic [NB-1:0] r_act, r_pre, r_rd, r_wr;
  logic        r_ref;
  always_comb begin
    r_ref = 1'b1;
    for (int b = 0; b < NB; b++) begin
      int g;
      g = b >> BA_W;
      r_act[b] = s_act[b] >= T_RC && s_pre[b] >= T_RP && s_ref >= T_RFC &&
                 s_actg[g] >= T_RRD_L && s_actc >= T_RRD_S && popc(acts) < 4;
      r_pre[b] = s_act[b] >= T_RAS && s_rd[b] >= T_RTP && s_wr[b] >= WR2PRE;
      r_rd[b]  = s_act[b] >= T_RCD && s_colg[g] >= T_CCD_L && s_wrg[g] >= WR2RD_L &&
                 s_col >= T_CCD_S && s_wrc >= WR2RD_S;
      r_wr[b]  = s_act[b] >= T_RCD && s_colg[g] >= T_CCD_L &&
                 s_col >= T_CCD_S && s_rdc >= T_RTW;
      r_ref    = r_ref && s_act[b] >= T_RC && s_pre[b] >= T_RP && s_ref >= T_RFC;
    end
  end

  // ---------------- environment ----------------
  initial assume (!rst_n);
  always @(*) if (rst_n && act) assume (act_ok[row_bank]);

  // ---------------- properties ----------------
  always @(*) if (rst_n) begin
    a_act: assert (act_ok == r_act);
    a_pre: assert (pre_ok == r_pre);
    a_rd:  assert (rd_ok  == r_rd);
    a_wr:  assert (wr_ok  == r_wr);
    a_ref: assert (ref_ok == r_ref);
  end

  // Reachability sanity: the interesting states actually occur.
  always @(*) if (rst_n) begin
    c_faw_block: cover (!act_ok[0] && s_act[0] == SAT[4:0] && s_actc >= T_RRD_S && s_actg[0] >= T_RRD_L);
    c_wtr_block: cover (!rd_ok[1] && s_act[1] >= T_RCD && s_wrg[0] < WR2RD_L);
  end
endmodule
