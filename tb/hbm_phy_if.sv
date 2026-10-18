// PHY-side command/data buses, white-box scheduler status, and the
// error-injection handshake into the device model.
interface hbm_phy_if (input logic clk, input logic rst_n);
  import hbm_pkg::*;
  // DFI-style buses (observed only)
  rcmd_e        row_cmd;
  logic [1:0]   row_bg, row_ba;
  logic [13:0]  row_addr;
  ccmd_e        col_cmd;
  logic [1:0]   col_bg, col_ba;
  logic [4:0]   col_addr;
  logic         wrdata_en;
  logic         rddata_valid;

  // Scheduler / controller status (white-box taps)
  logic [4:0]   q_count;
  logic         in_write_mode;
  logic         in_refresh;
  logic         starve;
  logic [3:0]   ref_owed;
  logic         rd_credit_ok;
  logic         req_valid, req_ready;
  logic [31:0]  perf_rd, perf_wr, perf_act, perf_pre, perf_ref, perf_turn;
  logic [15:0]  ecc_ce_cnt, ecc_ue_cnt;

  // Error injection: testbench raises inj_req with a byte address and a
  // 288-bit flip mask; tb_top waits for the controller and model to go
  // quiet, flips the stored word, then pulses inj_done.
  logic         inj_req;
  logic [27:0]  inj_addr;
  logic [287:0] inj_mask;
  logic         inj_done;
endinterface
