// Sequences. Each one targets a specific part of the scheduler; the
// random ones exist to find what the targeted ones did not think of.
class hbm_base_seq extends uvm_sequence #(axi_item);
  `uvm_object_utils(hbm_base_seq)
  hbm_cfg cfg;
  int unsigned n = 200;

  function new(string name = "hbm_base_seq");
    super.new(name);
  endfunction

  task send(axi_item::kind_e k, bit [3:0] id, bit [27:0] addr, bit [7:0] len,
            int unsigned delay = 0);
    axi_item it = axi_item::type_id::create("it");
    start_item(it);
    it.kind = k; it.id = id; it.addr = addr & ~28'h1F; it.len = len; it.delay = delay;
    if (k == axi_item::WRITE) it.fill_data();
    finish_item(it);
  endtask

  task send_rand(bit [27:0] base = 0, bit [27:0] span = 28'hFFF_FFFF);
    axi_item it = axi_item::type_id::create("it");
    start_item(it);
    it.rand_fields(base, span);
    if (it.kind == axi_item::WRITE) it.fill_data();
    finish_item(it);
  endtask

  task wait_cycles(int c);
    repeat (c) @(posedge cfg.phy.clk);
  endtask
endclass

// Fully random mix over a small window so reads hit earlier writes.
class hbm_rand_seq extends hbm_base_seq;
  `uvm_object_utils(hbm_rand_seq)
  bit [27:0] base = 0, span = 28'h0040000;   // 256 KB: 16 banks x a few rows
  function new(string name = "hbm_rand_seq"); super.new(name); endfunction
  task body();
    repeat (n) send_rand(base, span);
  endtask
endclass

// Sequential streaming: long runs of row hits, all bank groups in turn.
class hbm_stream_seq extends hbm_base_seq;
  `uvm_object_utils(hbm_stream_seq)
  function new(string name = "hbm_stream_seq"); super.new(name); endfunction
  task body();
    bit [27:0] a = 28'h0100000;
    for (int i = 0; i < n; i++) begin
      send(axi_item::WRITE, 4'(i), a + 28'(i * 32 * 4), 3);
    end
    for (int i = 0; i < n; i++) begin
      send(axi_item::READ, 4'(i), a + 28'(i * 32 * 4), 3);
    end
    // Long bursts, up to a full 4 KB (128 beats), each 4 KB aligned.
    for (int i = 0; i < 8; i++) begin
      bit [7:0] len = 8'($urandom_range(16, 127));
      bit [27:0] b  = 28'h0180000 + 28'(i * 4096);
      send(axi_item::WRITE, 4'(i), b, len);
      send(axi_item::READ,  4'(i + 8), b, len);
    end
  endtask
endclass

// Same bank, rotating rows: every access is a row conflict.
class hbm_conflict_seq extends hbm_base_seq;
  `uvm_object_utils(hbm_conflict_seq)
  function new(string name = "hbm_conflict_seq"); super.new(name); endfunction
  task body();
    for (int i = 0; i < n; i++) begin
      bit [3:0]  bk  = 4'($urandom_range(0, 15));
      bit [13:0] row = 14'($urandom_range(0, 3));
      bit [27:0] a   = cfg.make_addr(row, bk, 5'($urandom));
      send(($urandom_range(0, 3) == 0) ? axi_item::WRITE : axi_item::READ, 4'(i), a, 0);
    end
  endtask
endclass

// ACT storm: every request opens a fresh row in a different bank, which
// is what makes tRRD_S/tRRD_L/tFAW the limiter.
class hbm_faw_seq extends hbm_base_seq;
  `uvm_object_utils(hbm_faw_seq)
  function new(string name = "hbm_faw_seq"); super.new(name); endfunction
  task body();
    for (int i = 0; i < n; i++) begin
      bit [3:0]  bk  = 4'(i);
      bit [13:0] row = 14'(100 + i / 16);
      send(axi_item::READ, 4'(i), cfg.make_addr(row, bk, 0), 0);
    end
  endtask
endclass

// Read-after-write, write-after-write and write-after-read to one address
// without waiting for B. Only same-address ordering in the scheduler
// keeps these correct.
class hbm_hazard_seq extends hbm_base_seq;
  `uvm_object_utils(hbm_hazard_seq)
  function new(string name = "hbm_hazard_seq"); super.new(name); endfunction
  task body();
    for (int i = 0; i < n; i++) begin
      bit [27:0] a = 28'h0200000 + 28'($urandom_range(0, 31) * 32);
      case ($urandom_range(0, 2))
        0: begin send(axi_item::WRITE, 4'(i), a, 0); send(axi_item::READ, 4'(i + 1), a, 0); end
        1: begin send(axi_item::WRITE, 4'(i), a, 0); send(axi_item::WRITE, 4'(i + 2), a, 0);
                 send(axi_item::READ,  4'(i + 3), a, 0); end
        default: begin send(axi_item::READ, 4'(i), a, 0); send(axi_item::WRITE, 4'(i + 4), a, 0);
                       send(axi_item::READ, 4'(i + 5), a, 0); end
      endcase
    end
  endtask
endclass

// Write bursts big enough to cross the drain high watermark, with reads
// interleaved so the scheduler keeps switching modes.
class hbm_wdrain_seq extends hbm_base_seq;
  `uvm_object_utils(hbm_wdrain_seq)
  function new(string name = "hbm_wdrain_seq"); super.new(name); endfunction
  task body();
    for (int r = 0; r < n / 20; r++) begin
      for (int i = 0; i < 16; i++)
        send(axi_item::WRITE, 4'(i), 28'h0300000 + 28'($urandom_range(0, 1023) * 32), 0);
      for (int i = 0; i < 4; i++)
        send(axi_item::READ, 4'(i), 28'h0300000 + 28'($urandom_range(0, 1023) * 32), 1);
    end
  endtask
endclass

// One read to a conflicting row behind a flood of row hits to the same
// bank. FR-FCFS would serve the hits forever; the starvation limit must
// step in. The latency bound in cfg catches it if it does not.
class hbm_starve_seq extends hbm_base_seq;
  `uvm_object_utils(hbm_starve_seq)
  function new(string name = "hbm_starve_seq"); super.new(name); endfunction
  task body();
    bit [27:0] hot    = cfg.make_addr(14'd5, 4'd0, 0);
    bit [27:0] victim = cfg.make_addr(14'd9, 4'd0, 0);
    for (int i = 0; i < 24; i++) send(axi_item::READ, 4'(i % 15), hot + 28'((i % 32) * 32), 0);
    send(axi_item::READ, 4'd15, victim, 0);
    for (int i = 0; i < n; i++) begin
      bit [27:0] a = cfg.make_addr(14'd5, 4'd0, 5'(i));
      send(axi_item::READ, 4'(i % 15), a, 0);
    end
  endtask
endclass

// Partial write strobes must come back SLVERR and leave memory untouched.
class hbm_strobe_seq extends hbm_base_seq;
  `uvm_object_utils(hbm_strobe_seq)
  function new(string name = "hbm_strobe_seq"); super.new(name); endfunction
  task body();
    for (int i = 0; i < n; i++) begin
      axi_item it = axi_item::type_id::create("it");
      bit [27:0] a = 28'h0400000 + 28'($urandom_range(0, 63) * 32);
      start_item(it);
      it.kind = axi_item::WRITE; it.id = 4'(i); it.addr = a; it.len = 8'($urandom_range(0, 3));
      it.delay = 0;
      it.fill_data();
      if ($urandom_range(0, 1)) it.strb[$urandom_range(0, int'(it.len))] = 32'($urandom) & 32'h7FFF_FFFF;
      finish_item(it);
      send(axi_item::READ, 4'(i + 1), a, it.len, 2);
    end
  endtask
endclass

// ECC: write known data, flip one or two bits in the stored word, read it
// back. Single flips must correct (and count), double flips must SLVERR.
class hbm_ecc_seq extends hbm_base_seq;
  `uvm_object_utils(hbm_ecc_seq)
  function new(string name = "hbm_ecc_seq"); super.new(name); endfunction

  task inject(bit [27:0] a, bit dbl);
    bit [287:0] m;
    int lane = $urandom_range(0, 3);
    int b0, b1;
    // stay inside one 64+8 bit SECDED lane: data bits lane*64.., check bits 256+lane*8..
    b0 = $urandom_range(0, 71);
    do b1 = $urandom_range(0, 71); while (b1 == b0);
    m = '0;
    m[(b0 < 64) ? lane * 64 + b0 : 256 + lane * 8 + (b0 - 64)] = 1'b1;
    if (dbl) m[(b1 < 64) ? lane * 64 + b1 : 256 + lane * 8 + (b1 - 64)] = 1'b1;
    @(posedge cfg.phy.clk);
    cfg.phy.inj_addr <= a;
    cfg.phy.inj_mask <= m;
    cfg.phy.inj_req  <= 1;
    while (!cfg.phy.inj_done) @(posedge cfg.phy.clk);
    cfg.sb.note_injection(a, dbl);
    cfg.phy.inj_req <= 0;
    @(posedge cfg.phy.clk);
  endtask

  task body();
    for (int i = 0; i < n; i++) begin
      bit [27:0] a = 28'h0500000 + 28'(i * 32);
      bit dbl = (i % 3 == 2);
      send(axi_item::WRITE, 4'(i), a, 0);
      // The driver may still be draining earlier sequences; inject only
      // after this write is acknowledged (tb_top then waits for it to land).
      while (!cfg.sb.write_acked(a)) wait_cycles(1);
      inject(a, dbl);
      send(axi_item::READ, 4'(i), a, 0);
      if (i % 4 == 0) send(axi_item::READ, 4'(i + 1), a, 0);     // second read sees it again
      if (i % 5 == 0) begin                                       // overwrite clears it
        wait_cycles(20);
        send(axi_item::WRITE, 4'(i), a, 0);
        send(axi_item::READ, 4'(i + 2), a, 0);
      end
      wait_cycles(20);
    end
  endtask
endclass

// Saturating conflict traffic with no idle gaps, so the queue never empties
// and owed refreshes pile up until refresh goes urgent.
class hbm_refresh_seq extends hbm_base_seq;
  `uvm_object_utils(hbm_refresh_seq)
  function new(string name = "hbm_refresh_seq"); super.new(name); endfunction
  task body();
    for (int i = 0; i < n; i++) begin
      bit [3:0]  bk  = 4'($urandom_range(0, 15));
      bit [13:0] row = 14'($urandom_range(0, 63));
      send(($urandom_range(0, 4) == 0) ? axi_item::WRITE : axi_item::READ, 4'(i),
           cfg.make_addr(row, bk, 5'($urandom)), 0);
    end
  endtask
endclass
