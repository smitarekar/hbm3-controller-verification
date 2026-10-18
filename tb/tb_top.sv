// Top level for the UVM environment: hbm3_ctrl + behavioral HBM3 model,
// with JEDEC timing assertions bound onto the controller's PHY outputs.
module tb_top;
  import uvm_pkg::*;
  import hbm_pkg::*;
  import hbm_uvm_pkg::*;

  parameter int POLICY   = 1;
  parameter int ADDR_MAP = 0;

  logic clk = 0, rst_n = 0;
  always #1 clk = ~clk;          // 2 ns period: posedge at even ns
  initial begin
    repeat (8) @(posedge clk);
    rst_n = 1;
  end

  hbm_axi_if axi (.clk, .rst_n);
  hbm_phy_if phy (.clk, .rst_n);

  logic [287:0] wrdata, rddata;
  logic [31:0]  perf_rd, perf_wr, perf_act, perf_pre, perf_ref, perf_turn;
  logic [15:0]  ecc_ce_cnt, ecc_ue_cnt;

  hbm3_ctrl #(.POLICY(POLICY), .ADDR_MAP(ADDR_MAP)) dut (
    .clk, .rst_n,
    .s_awvalid(axi.awvalid), .s_awready(axi.awready), .s_awid(axi.awid),
    .s_awaddr(axi.awaddr), .s_awlen(axi.awlen),
    .s_wvalid(axi.wvalid), .s_wready(axi.wready), .s_wdata(axi.wdata),
    .s_wstrb(axi.wstrb), .s_wlast(axi.wlast),
    .s_bvalid(axi.bvalid), .s_bready(axi.bready), .s_bid(axi.bid), .s_bresp(axi.bresp),
    .s_arvalid(axi.arvalid), .s_arready(axi.arready), .s_arid(axi.arid),
    .s_araddr(axi.araddr), .s_arlen(axi.arlen),
    .s_rvalid(axi.rvalid), .s_rready(axi.rready), .s_rid(axi.rid),
    .s_rdata(axi.rdata), .s_rresp(axi.rresp), .s_rlast(axi.rlast),
    .dfi_row_cmd(phy.row_cmd), .dfi_row_bg(phy.row_bg), .dfi_row_ba(phy.row_ba),
    .dfi_row_addr(phy.row_addr),
    .dfi_col_cmd(phy.col_cmd), .dfi_col_bg(phy.col_bg), .dfi_col_ba(phy.col_ba),
    .dfi_col_addr(phy.col_addr),
    .dfi_wrdata_en(phy.wrdata_en), .dfi_wrdata(wrdata),
    .dfi_rddata_valid(phy.rddata_valid), .dfi_rddata(rddata),
    .perf_rd, .perf_wr, .perf_act, .perf_pre, .perf_ref, .perf_turn,
    .ecc_ce_cnt, .ecc_ue_cnt
  );

  hbm3_pc_model mdl (
    .clk, .rst_n,
    .row_cmd(phy.row_cmd), .row_bg(phy.row_bg), .row_ba(phy.row_ba), .row_addr(phy.row_addr),
    .col_cmd(phy.col_cmd), .col_bg(phy.col_bg), .col_ba(phy.col_ba), .col_addr(phy.col_addr),
    .wrdata_en(phy.wrdata_en), .wrdata(wrdata),
    .rddata_valid(phy.rddata_valid), .rddata(rddata)
  );

  // ---------------- white-box status taps ----------------
  assign phy.q_count       = dut.u_sched.q_count;
  assign phy.in_write_mode = dut.u_sched.in_write_mode;
  assign phy.in_refresh    = dut.u_sched.in_refresh;
  assign phy.starve        = dut.u_sched.starve;
  assign phy.ref_owed      = dut.u_refresh.owed;
  assign phy.rd_credit_ok  = dut.rd_credit_ok;
  assign phy.req_valid     = dut.req_valid;
  assign phy.req_ready     = dut.req_ready;
  assign phy.perf_rd   = perf_rd;   assign phy.perf_wr  = perf_wr;
  assign phy.perf_act  = perf_act;  assign phy.perf_pre = perf_pre;
  assign phy.perf_ref  = perf_ref;  assign phy.perf_turn = perf_turn;
  assign phy.ecc_ce_cnt = ecc_ce_cnt;
  assign phy.ecc_ue_cnt = ecc_ue_cnt;

  // ---------------- error injection ----------------
  function automatic logic [22:0] model_key(logic [27:0] a);
    logic [1:0] bg, ba; logic [4:0] co; logic [13:0] ro;
    if (ADDR_MAP == 0) begin co = a[9:5]; bg = a[11:10]; ba = a[13:12]; end
    else begin bg = a[6:5]; ba = a[8:7]; co = a[13:9]; end
    ro = a[27:14];
    return {bg, ba, ro, co};
  endfunction

  initial phy.inj_done = 0;
  always @(posedge clk) begin
    if (phy.inj_req && !phy.inj_done) begin
      // Quiet for 4 straight cycles: nothing queued, no column command on
      // the bus, no write data still in flight to the model. One cycle is
      // not enough: a WR leaves the queue one cycle before it reaches the
      // PHY bus and two before the model records it.
      automatic int quiet = 0;
      while (quiet < 4) begin
        @(posedge clk);
        if (dut.u_sched.q_count == 0 && mdl.wq.size() == 0 &&
            phy.col_cmd == CCMD_NOP && dut.col_cmd == CCMD_NOP) quiet++;
        else quiet = 0;
      end
      mdl.inject_flip(model_key(phy.inj_addr), phy.inj_mask);
      phy.inj_done <= 1;
    end else if (!phy.inj_req) begin
      phy.inj_done <= 0;
    end
  end

  // ---------------- UVM ----------------
  initial begin
    uvm_config_db#(virtual hbm_axi_if)::set(null, "*", "axi_vif", axi);
    uvm_config_db#(virtual hbm_phy_if)::set(null, "*", "phy_vif", phy);
    uvm_config_db#(int)::set(null, "*", "addr_map", ADDR_MAP);
    uvm_config_db#(int)::set(null, "*", "policy", POLICY);
    run_test();
  end

  // Model-side protocol violations are reported as UVM errors at the end.
  final begin
    if (mdl.violations != 0)
      $display("UVM_ERROR tb_top: device model flagged %0d JEDEC violations", mdl.violations);
  end
endmodule

bind hbm3_ctrl hbm_jedec_sva u_jedec_sva (
  .clk, .rst_n,
  .row_cmd(dfi_row_cmd), .row_bg(dfi_row_bg), .row_ba(dfi_row_ba),
  .col_cmd(dfi_col_cmd), .col_bg(dfi_col_bg), .col_ba(dfi_col_ba),
  .wrdata_en(dfi_wrdata_en),
  .ref_owed(u_refresh.owed)
);

bind hbm3_ctrl hbm_axi_sva u_axi_sva (
  .clk, .rst_n,
  .bvalid(s_bvalid), .bready(s_bready), .bid(s_bid), .bresp(s_bresp),
  .rvalid(s_rvalid), .rready(s_rready), .rid(s_rid), .rdata(s_rdata),
  .rresp(s_rresp), .rlast(s_rlast),
  .awvalid(s_awvalid), .awready(s_awready),
  .arvalid(s_arvalid), .arready(s_arready),
  .wvalid(s_wvalid), .wready(s_wready)
);
