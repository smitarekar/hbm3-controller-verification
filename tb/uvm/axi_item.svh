// One AXI burst, as requested by a sequence and as observed by the monitor.
class axi_item extends uvm_sequence_item;
  `uvm_object_utils(axi_item)

  typedef enum bit {READ, WRITE} kind_e;

  rand kind_e      kind;
  rand bit [3:0]   id;
  rand bit [27:0]  addr;
  rand bit [7:0]   len;
  rand int unsigned delay;      // idle cycles before the driver issues it
  bit [255:0]      data [$];    // write data (driver) or read data (monitor)
  bit [31:0]       strb [$];
  bit [1:0]        resp [$];    // per-beat RRESP, or BRESP in [0]
  longint          t_req;       // AW/AR handshake cycle
  longint          t_done;      // B or RLAST handshake cycle
  longint          beat_t [$];  // per-beat handshake cycle (R beats)

`ifdef HBM_USE_SOLVER
  // Used when Verilator has an SMT solver (z3/cvc5) on PATH.
  constraint c_align { addr[4:0] == 0; }
  constraint c_len   { len dist {0 := 40, [1:3] := 30, [4:7] := 20, [8:15] := 10}; }
  constraint c_4k    { (addr[11:0] + (len + 1) * 32) <= 4096; }
  constraint c_delay { delay dist {0 := 70, [1:4] := 25, [5:40] := 5}; }
`endif

  function new(string name = "axi_item");
    super.new(name);
  endfunction

  // Procedural randomization with the same distributions as the
  // constraint blocks above, so the build needs no external solver.
  function void rand_fields(bit [27:0] base = 0, bit [27:0] span = 28'hFFF_FFFF);
`ifdef HBM_USE_SOLVER
    if (!this.randomize()) `uvm_fatal("RAND", "randomize failed")
    addr = (base + (addr % span)) & ~28'h1F;
    if ((addr[11:0] + (len + 1) * 32) > 4096) len = 0;
`else
    int unsigned r;
    kind  = ($urandom_range(0, 1) != 0) ? WRITE : READ;
    id    = 4'($urandom);
    r     = $urandom_range(0, 99);
    len   = (r < 40) ? 8'd0 : (r < 70) ? 8'($urandom_range(1, 3)) :
            (r < 90) ? 8'($urandom_range(4, 7)) : 8'($urandom_range(8, 15));
    addr  = (base + 28'($urandom % span)) & ~28'h1F;
    if ((32'(addr[11:0]) + (32'(len) + 1) * 32) > 4096) len = 0;
    r     = $urandom_range(0, 99);
    delay = (r < 70) ? 0 : (r < 95) ? $urandom_range(1, 4) : $urandom_range(5, 40);
`endif
  endfunction

  function void fill_data();
    data.delete();
    strb.delete();
    for (int i = 0; i <= int'(len); i++) begin
      data.push_back({$urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom});
      strb.push_back('1);
    end
  endfunction

  function string convert2string();
    return $sformatf("%s id=%0d addr=%07h len=%0d", kind.name(), id, addr, len);
  endfunction
endclass

// One PHY-side command cycle (row and/or column command).
class dfi_item extends uvm_sequence_item;
  `uvm_object_utils(dfi_item)
  hbm_pkg::rcmd_e row_cmd;
  bit [3:0]       row_bank;
  bit [13:0]      row_addr;
  hbm_pkg::ccmd_e col_cmd;
  bit [3:0]       col_bank;
  bit [4:0]       col_addr;
  longint         t;
  function new(string name = "dfi_item");
    super.new(name);
  endfunction
endclass
