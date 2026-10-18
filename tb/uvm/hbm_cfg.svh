// Environment configuration and the shared knobs sequences can turn.
typedef class hbm_scoreboard;

class hbm_cfg extends uvm_object;
  `uvm_object_utils(hbm_cfg)

  int addr_map = 0;
  int policy   = 1;

  // Driver backpressure (percent of cycles the ready is held low)
  int unsigned rready_low_pct = 0;
  int unsigned bready_low_pct = 0;

  // Outstanding transaction cap per direction in the driver
  int unsigned max_outstanding = 32;

  // Read latency budget checked by the scoreboard (cycles, AR to RLAST)
  int unsigned max_rd_latency = 4000;

  // Handles sequences need for error injection
  virtual hbm_phy_if phy;
  hbm_scoreboard     sb;

  function new(string name = "hbm_cfg");
    super.new(name);
  endfunction

  // Address map helpers, mirroring hbm_axi_fe
  function bit [3:0] bank_of(bit [27:0] a);
    if (addr_map == 0) return {a[11:10], a[13:12]};
    else               return {a[6:5],  a[8:7]};
  endfunction

  function bit [13:0] row_of(bit [27:0] a);
    return a[27:14];
  endfunction

  // Build an address from {row, bank, col}, honoring the map
  function bit [27:0] make_addr(bit [13:0] row, bit [3:0] bank, bit [4:0] col);
    bit [27:0] a = '0;
    a[27:14] = row;
    if (addr_map == 0) begin
      a[9:5] = col; a[11:10] = bank[3:2]; a[13:12] = bank[1:0];
    end else begin
      a[6:5] = bank[3:2]; a[8:7] = bank[1:0]; a[13:9] = col;
    end
    return a;
  endfunction
endclass
