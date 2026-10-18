// AXI4 manager driver with independent AW, W and AR channel processes, so
// many bursts can be outstanding at once (the scheduler needs a deep queue
// to have anything to reorder).
//
// Timing discipline: outputs change only with nonblocking assignments
// right after a posedge; handshakes are read at the following negedge,
// when every combinational ready has settled. A handshake seen at a
// negedge completes on the next posedge.
class axi_driver extends uvm_driver #(axi_item);
  `uvm_component_utils(axi_driver)

  virtual hbm_axi_if vif;
  hbm_cfg cfg;

  axi_item    aw_q [$];
  axi_item    ar_q [$];
  bit [255:0] w_data_q [$];
  bit [31:0]  w_strb_q [$];
  bit         w_last_q [$];

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual hbm_axi_if)::get(this, "", "axi_vif", vif))
      `uvm_fatal("NOVIF", "axi_vif not set")
    if (!uvm_config_db#(hbm_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("NOCFG", "cfg not set")
  endfunction

  task run_phase(uvm_phase phase);
    vif.awvalid <= 0; vif.wvalid <= 0; vif.arvalid <= 0;
    vif.awid <= 0; vif.awaddr <= 0; vif.awlen <= 0;
    vif.wdata <= 0; vif.wstrb <= 0; vif.wlast <= 0;
    vif.arid <= 0; vif.araddr <= 0; vif.arlen <= 0;
    vif.bready <= 1; vif.rready <= 1;
    wait (vif.rst_n === 1'b1);
    fork
      get_items();
      drive_aw();
      drive_w();
      drive_ar();
      drive_ready();
    join_none
  endtask

  task get_items();
    forever begin
      axi_item it;
      seq_item_port.get_next_item(it);
      repeat (it.delay) @(posedge vif.clk);
      if (it.kind == axi_item::WRITE) begin
        while (aw_q.size() >= cfg.max_outstanding) @(posedge vif.clk);
        aw_q.push_back(it);
        foreach (it.data[i]) begin
          w_data_q.push_back(it.data[i]);
          w_strb_q.push_back(it.strb[i]);
          w_last_q.push_back(i == int'(it.len));
        end
      end else begin
        while (ar_q.size() >= cfg.max_outstanding) @(posedge vif.clk);
        ar_q.push_back(it);
      end
      seq_item_port.item_done();
    end
  endtask

  task drive_aw();
    axi_item cur;
    forever begin
      @(posedge vif.clk);
      if (cur == null && aw_q.size() != 0) cur = aw_q.pop_front();
      if (cur != null) begin
        vif.awvalid <= 1; vif.awid <= cur.id; vif.awaddr <= cur.addr; vif.awlen <= cur.len;
      end else vif.awvalid <= 0;
      @(negedge vif.clk);
      if (cur != null && vif.awvalid && vif.awready) cur = null;
    end
  endtask

  task drive_w();
    bit busy;
    forever begin
      @(posedge vif.clk);
      if (!busy && w_data_q.size() != 0) begin
        vif.wvalid <= 1;
        vif.wdata  <= w_data_q.pop_front();
        vif.wstrb  <= w_strb_q.pop_front();
        vif.wlast  <= w_last_q.pop_front();
        busy = 1;
      end else if (!busy) vif.wvalid <= 0;
      @(negedge vif.clk);
      if (busy && vif.wvalid && vif.wready) busy = 0;
    end
  endtask

  task drive_ar();
    axi_item cur;
    forever begin
      @(posedge vif.clk);
      if (cur == null && ar_q.size() != 0) cur = ar_q.pop_front();
      if (cur != null) begin
        vif.arvalid <= 1; vif.arid <= cur.id; vif.araddr <= cur.addr; vif.arlen <= cur.len;
      end else vif.arvalid <= 0;
      @(negedge vif.clk);
      if (cur != null && vif.arvalid && vif.arready) cur = null;
    end
  endtask

  task drive_ready();
    forever begin
      @(posedge vif.clk);
      vif.rready <= ($urandom_range(0, 99) >= cfg.rready_low_pct);
      vif.bready <= ($urandom_range(0, 99) >= cfg.bready_low_pct);
    end
  endtask

  function bit idle();
    return aw_q.size() == 0 && ar_q.size() == 0 && w_data_q.size() == 0;
  endfunction
endclass

class axi_sequencer extends uvm_sequencer #(axi_item);
  `uvm_component_utils(axi_sequencer)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
endclass
