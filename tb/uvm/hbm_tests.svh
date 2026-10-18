// Tests. The base test builds the env, runs body(), then waits until the
// AXI monitor has nothing outstanding and the controller queue is empty.
class hbm_base_test extends uvm_test;
  `uvm_component_utils(hbm_base_test)

  hbm_env env;
  hbm_cfg cfg;
  int unsigned drain_timeout = 200000;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    cfg = hbm_cfg::type_id::create("cfg");
    void'(uvm_config_db#(int)::get(this, "", "addr_map", cfg.addr_map));
    void'(uvm_config_db#(int)::get(this, "", "policy", cfg.policy));
    if (!uvm_config_db#(virtual hbm_phy_if)::get(this, "", "phy_vif", cfg.phy))
      `uvm_fatal("NOVIF", "phy_vif not set")
    configure();
    uvm_config_db#(hbm_cfg)::set(this, "*", "cfg", cfg);
    env = hbm_env::type_id::create("env", this);
  endfunction

  virtual function void configure();
  endfunction

  virtual task body();
  endtask

  function void start_of_simulation_phase(uvm_phase phase);
    `uvm_info("TEST", $sformatf("policy=%0s addr_map=%0d", cfg.policy ? "FR-FCFS" : "FCFS",
                                cfg.addr_map), UVM_NONE)
  endfunction

  task run_phase(uvm_phase phase);
    int quiet = 0, waited = 0;
    phase.raise_objection(this);
    cfg.phy.inj_req <= 0;
    wait (cfg.phy.rst_n === 1'b1);
    repeat (5) @(posedge cfg.phy.clk);
    body();
    while (quiet < 100 && waited < drain_timeout) begin
      @(posedge cfg.phy.clk);
      waited++;
      if (env.agt.mon.outstanding() == 0 && env.agt.drv.idle() && cfg.phy.q_count == 0) quiet++;
      else quiet = 0;
    end
    if (waited >= drain_timeout)
      `uvm_error("TEST", $sformatf("did not drain: %0d bursts outstanding", env.agt.mon.outstanding()))
    phase.drop_objection(this);
  endtask

  // Run a sequence on the AXI sequencer.
  task run_seq(hbm_base_seq s, int unsigned n);
    s.cfg = cfg;
    s.n   = n;
    s.start(env.agt.sqr);
  endtask
endclass

class hbm_smoke_test extends hbm_base_test;
  `uvm_component_utils(hbm_smoke_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    hbm_rand_seq s = hbm_rand_seq::type_id::create("s");
    run_seq(s, 100);
  endtask
endclass

class hbm_rand_test extends hbm_base_test;
  `uvm_component_utils(hbm_rand_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void configure();
    cfg.rready_low_pct = 10;
    cfg.bready_low_pct = 10;
  endfunction
  task body();
    hbm_rand_seq s = hbm_rand_seq::type_id::create("s");
    run_seq(s, 3000);
  endtask
endclass

class hbm_stream_test extends hbm_base_test;
  `uvm_component_utils(hbm_stream_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    hbm_stream_seq s = hbm_stream_seq::type_id::create("s");
    run_seq(s, 512);
  endtask
endclass

class hbm_conflict_test extends hbm_base_test;
  `uvm_component_utils(hbm_conflict_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    hbm_conflict_seq c = hbm_conflict_seq::type_id::create("c");
    hbm_faw_seq      f = hbm_faw_seq::type_id::create("f");
    run_seq(c, 1500);
    run_seq(f, 512);
  endtask
endclass

class hbm_hazard_test extends hbm_base_test;
  `uvm_component_utils(hbm_hazard_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    hbm_hazard_seq s = hbm_hazard_seq::type_id::create("s");
    run_seq(s, 800);
  endtask
endclass

class hbm_wdrain_test extends hbm_base_test;
  `uvm_component_utils(hbm_wdrain_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    hbm_wdrain_seq s = hbm_wdrain_seq::type_id::create("s");
    run_seq(s, 1000);
  endtask
endclass

class hbm_starve_test extends hbm_base_test;
  `uvm_component_utils(hbm_starve_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void configure();
    // STARVE=256 plus the worst-case row cycle and queue drain
    cfg.max_rd_latency = 700;
  endfunction
  task body();
    hbm_starve_seq s = hbm_starve_seq::type_id::create("s");
    run_seq(s, 2000);
  endtask
endclass

// Long enough, and busy enough, that refresh must go urgent.
class hbm_refresh_test extends hbm_base_test;
  `uvm_component_utils(hbm_refresh_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void configure();
    cfg.max_rd_latency = 8000;
  endfunction
  task body();
    hbm_refresh_seq s = hbm_refresh_seq::type_id::create("s");
    hbm_rand_seq    r = hbm_rand_seq::type_id::create("r");
    run_seq(s, 2500);                         // ~25k busy cycles: urgent refresh
    run_seq(r, 1000);
    repeat (20000) @(posedge cfg.phy.clk);    // idle: opportunistic refresh
  endtask
endclass

class hbm_ecc_test extends hbm_base_test;
  `uvm_component_utils(hbm_ecc_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    hbm_ecc_seq s = hbm_ecc_seq::type_id::create("s");
    run_seq(s, 60);
  endtask
endclass

class hbm_strobe_test extends hbm_base_test;
  `uvm_component_utils(hbm_strobe_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  task body();
    hbm_strobe_seq s = hbm_strobe_seq::type_id::create("s");
    run_seq(s, 200);
  endtask
endclass

// Heavy R/B backpressure: the read buffer fills, credits run out, and
// the scheduler must stop issuing RDs rather than drop data.
class hbm_backpressure_test extends hbm_base_test;
  `uvm_component_utils(hbm_backpressure_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void configure();
    cfg.rready_low_pct = 85;
    cfg.bready_low_pct = 60;
    cfg.max_rd_latency = 20000;
  endfunction
  task body();
    hbm_stream_seq s = hbm_stream_seq::type_id::create("s");
    hbm_rand_seq   r = hbm_rand_seq::type_id::create("r");
    run_seq(s, 128);
    run_seq(r, 600);
  endtask
endclass

// Everything, back to back, in one run.
class hbm_full_test extends hbm_base_test;
  `uvm_component_utils(hbm_full_test)
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void configure();
    cfg.rready_low_pct = 5;
    cfg.max_rd_latency = 8000;
  endfunction
  task body();
    hbm_stream_seq   s1 = hbm_stream_seq::type_id::create("s1");
    hbm_conflict_seq s2 = hbm_conflict_seq::type_id::create("s2");
    hbm_faw_seq      s3 = hbm_faw_seq::type_id::create("s3");
    hbm_hazard_seq   s4 = hbm_hazard_seq::type_id::create("s4");
    hbm_wdrain_seq   s5 = hbm_wdrain_seq::type_id::create("s5");
    hbm_starve_seq   s6 = hbm_starve_seq::type_id::create("s6");
    hbm_strobe_seq   s7 = hbm_strobe_seq::type_id::create("s7");
    hbm_ecc_seq      s8 = hbm_ecc_seq::type_id::create("s8");
    hbm_rand_seq     s9 = hbm_rand_seq::type_id::create("s9");
    run_seq(s1, 256);
    run_seq(s2, 600);
    run_seq(s3, 256);
    run_seq(s4, 300);
    run_seq(s5, 400);
    run_seq(s6, 800);
    run_seq(s7, 60);
    run_seq(s8, 24);
    run_seq(s9, 4000);
  endtask
endclass
