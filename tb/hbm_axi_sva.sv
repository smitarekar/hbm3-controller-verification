// AXI4 handshake rules on the subordinate side of hbm3_ctrl, plus the
// manager-side rules as assumptions-by-assertion (they catch testbench
// driver bugs, which is where they usually fire).
module hbm_axi_sva (
  input logic         clk,
  input logic         rst_n,
  input logic         bvalid, bready,
  input logic [3:0]   bid,
  input logic [1:0]   bresp,
  input logic         rvalid, rready,
  input logic [3:0]   rid,
  input logic [255:0] rdata,
  input logic [1:0]   rresp,
  input logic         rlast,
  input logic         awvalid, awready,
  input logic         arvalid, arready,
  input logic         wvalid, wready
);
  default clocking cb @(posedge clk); endclocking
  default disable iff (!rst_n);

  // DUT outputs: once valid, hold until accepted, payload stable.
  a_b_hold:   assert property (bvalid && !bready |=> bvalid && $stable(bid) && $stable(bresp))
    else $error("B changed before handshake");
  a_r_hold:   assert property (rvalid && !rready |=> rvalid && $stable(rid) && $stable(rdata)
                                                    && $stable(rresp) && $stable(rlast))
    else $error("R changed before handshake");
  a_b_resp:   assert property (bvalid |-> bresp inside {2'b00, 2'b10})
    else $error("BRESP not OKAY/SLVERR");
  a_r_resp:   assert property (rvalid |-> rresp inside {2'b00, 2'b10})
    else $error("RRESP not OKAY/SLVERR");

  // Manager side: valid must not drop before ready.
  a_aw_hold:  assert property (awvalid && !awready |=> awvalid) else $error("AWVALID dropped");
  a_ar_hold:  assert property (arvalid && !arready |=> arvalid) else $error("ARVALID dropped");
  a_w_hold:   assert property (wvalid  && !wready  |=> wvalid)  else $error("WVALID dropped");

  c_r_stall:  cover property (rvalid && !rready ##1 rvalid && rready);
  c_b_stall:  cover property (bvalid && !bready ##1 bvalid && bready);
  c_ar_stall: cover property (arvalid && !arready);
endmodule
