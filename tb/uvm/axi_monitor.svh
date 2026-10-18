// Passive AXI monitor. Rebuilds bursts from channel handshakes and
// publishes:
//   ap_wbeat : each accepted W beat with its address (for the scoreboard's
//              ordering window), parent burst handle attached
//   ap_wdone : a write burst once its B arrives
//   ap_rdone : a read burst once its RLAST beat arrives
// Protocol checks that need transaction context (R with no AR, RLAST in
// the wrong place, B before all W beats) are done here.
class axi_wbeat extends uvm_object;
  `uvm_object_utils(axi_wbeat)
  bit [27:0]  addr;
  bit [255:0] data;
  bit         full_strb;
  longint     t;
  axi_item    burst;
  function new(string name = "axi_wbeat");
    super.new(name);
  endfunction
endclass

class axi_monitor extends uvm_monitor;
  `uvm_component_utils(axi_monitor)

  virtual hbm_axi_if vif;

  uvm_analysis_port #(axi_wbeat) ap_wbeat;
  uvm_analysis_port #(axi_item)  ap_wdone;
  uvm_analysis_port #(axi_item)  ap_rdone;

  longint  cyc;
  axi_item aw_open [$];          // AW seen, W beats still arriving (AW order)
  int      aw_beats [$];
  axi_item wait_b [16][$];       // all beats in, waiting for B, per ID
  axi_item rd_open [16][$];      // AR seen, per ID, in order

  int n_aw, n_ar, n_b, n_rbeats, n_rlast;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap_wbeat = new("ap_wbeat", this);
    ap_wdone = new("ap_wdone", this);
    ap_rdone = new("ap_rdone", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual hbm_axi_if)::get(this, "", "axi_vif", vif))
      `uvm_fatal("NOVIF", "axi_vif not set")
  endfunction

  function int outstanding();
    int n = aw_open.size();
    for (int i = 0; i < 16; i++) n += wait_b[i].size() + rd_open[i].size();
    return n;
  endfunction

  task run_phase(uvm_phase phase);
    wait (vif.rst_n === 1'b1);
    forever begin
      @(negedge vif.clk);
      cyc++;
      // ---- AW ----
      if (vif.awvalid && vif.awready) begin
        axi_item it = axi_item::type_id::create("aw");
        it.kind = axi_item::WRITE; it.id = vif.awid; it.addr = vif.awaddr; it.len = vif.awlen;
        it.t_req = cyc;
        aw_open.push_back(it);
        aw_beats.push_back(0);
        n_aw++;
      end
      // ---- W ----
      if (vif.wvalid && vif.wready) begin
        if (aw_open.size() == 0) `uvm_error("AXI", "W beat accepted with no open AW")
        else begin
          axi_item b = aw_open[0];
          axi_wbeat wb = axi_wbeat::type_id::create("wb");
          wb.addr = b.addr + 28'(aw_beats[0] * 32);
          wb.data = vif.wdata;
          wb.full_strb = (vif.wstrb == '1);
          wb.t = cyc;
          wb.burst = b;
          b.data.push_back(vif.wdata);
          b.strb.push_back(vif.wstrb);
          ap_wbeat.write(wb);
          if (vif.wlast != (aw_beats[0] == int'(b.len)))
            `uvm_error("AXI", $sformatf("WLAST misplaced on %s", b.convert2string()))
          if (aw_beats[0] == int'(b.len)) begin
            void'(aw_open.pop_front());
            void'(aw_beats.pop_front());
            wait_b[b.id].push_back(b);
          end else aw_beats[0]++;
        end
      end
      // ---- B ----
      if (vif.bvalid && vif.bready) begin
        n_b++;
        if (wait_b[vif.bid].size() == 0)
          `uvm_error("AXI", $sformatf("B for ID %0d with no completed write burst", vif.bid))
        else begin
          axi_item b = wait_b[vif.bid].pop_front();
          b.resp.push_back(vif.bresp);
          b.t_done = cyc;
          ap_wdone.write(b);
        end
      end
      // ---- AR ----
      if (vif.arvalid && vif.arready) begin
        axi_item it = axi_item::type_id::create("ar");
        it.kind = axi_item::READ; it.id = vif.arid; it.addr = vif.araddr; it.len = vif.arlen;
        it.t_req = cyc;
        rd_open[it.id].push_back(it);
        n_ar++;
      end
      // ---- R ----
      if (vif.rvalid && vif.rready) begin
        n_rbeats++;
        if (rd_open[vif.rid].size() == 0)
          `uvm_error("AXI", $sformatf("R beat for ID %0d with no outstanding AR", vif.rid))
        else begin
          axi_item r = rd_open[vif.rid][0];
          bit want_last = (r.data.size() == int'(r.len));
          r.data.push_back(vif.rdata);
          r.resp.push_back(vif.rresp);
          r.beat_t.push_back(cyc);
          if (vif.rlast != want_last)
            `uvm_error("AXI", $sformatf("RLAST=%0b on beat %0d of %s", vif.rlast,
                                        r.data.size() - 1, r.convert2string()))
          if (want_last) begin
            void'(rd_open[vif.rid].pop_front());
            r.t_done = cyc;
            n_rlast++;
            ap_rdone.write(r);
          end
        end
      end
    end
  endtask
endclass

// PHY command monitor: one item per cycle with any command.
class dfi_monitor extends uvm_monitor;
  `uvm_component_utils(dfi_monitor)
  virtual hbm_phy_if vif;
  uvm_analysis_port #(dfi_item) ap;
  longint cyc;
  int n_act, n_pre, n_ref, n_rd, n_wr;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual hbm_phy_if)::get(this, "", "phy_vif", vif))
      `uvm_fatal("NOVIF", "phy_vif not set")
  endfunction

  task run_phase(uvm_phase phase);
    wait (vif.rst_n === 1'b1);
    forever begin
      @(negedge vif.clk);
      cyc++;
      if (vif.row_cmd != hbm_pkg::RCMD_NOP || vif.col_cmd != hbm_pkg::CCMD_NOP) begin
        dfi_item d = dfi_item::type_id::create("d");
        d.row_cmd = vif.row_cmd; d.row_bank = {vif.row_bg, vif.row_ba}; d.row_addr = vif.row_addr;
        d.col_cmd = vif.col_cmd; d.col_bank = {vif.col_bg, vif.col_ba}; d.col_addr = vif.col_addr;
        d.t = cyc;
        case (vif.row_cmd)
          hbm_pkg::RCMD_ACT: n_act++;
          hbm_pkg::RCMD_PRE: n_pre++;
          hbm_pkg::RCMD_REF: n_ref++;
          default: ;
        endcase
        if (vif.col_cmd == hbm_pkg::CCMD_RD) n_rd++;
        if (vif.col_cmd == hbm_pkg::CCMD_WR) n_wr++;
        ap.write(d);
      end
    end
  endtask
endclass

class axi_agent extends uvm_agent;
  `uvm_component_utils(axi_agent)
  axi_driver    drv;
  axi_sequencer sqr;
  axi_monitor   mon;
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    drv = axi_driver::type_id::create("drv", this);
    sqr = axi_sequencer::type_id::create("sqr", this);
    mon = axi_monitor::type_id::create("mon", this);
  endfunction
  function void connect_phase(uvm_phase phase);
    drv.seq_item_port.connect(sqr.seq_item_export);
  endfunction
endclass
