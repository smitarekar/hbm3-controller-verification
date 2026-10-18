// AXI4 subset used by hbm3_ctrl (256-bit data, 4-bit IDs, 28-bit address).
interface hbm_axi_if (input logic clk, input logic rst_n);
  logic         awvalid, awready;
  logic [3:0]   awid;
  logic [27:0]  awaddr;
  logic [7:0]   awlen;
  logic         wvalid, wready;
  logic [255:0] wdata;
  logic [31:0]  wstrb;
  logic         wlast;
  logic         bvalid, bready;
  logic [3:0]   bid;
  logic [1:0]   bresp;
  logic         arvalid, arready;
  logic [3:0]   arid;
  logic [27:0]  araddr;
  logic [7:0]   arlen;
  logic         rvalid, rready;
  logic [3:0]   rid;
  logic [255:0] rdata;
  logic [1:0]   rresp;
  logic         rlast;
endinterface
