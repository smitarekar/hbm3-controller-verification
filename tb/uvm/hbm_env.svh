class hbm_env extends uvm_env;
  `uvm_component_utils(hbm_env)

  hbm_cfg        cfg;
  axi_agent      agt;
  dfi_monitor    dmon;
  hbm_scoreboard sb;
  hbm_coverage   cov;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(hbm_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("NOCFG", "cfg not set")
    agt  = axi_agent::type_id::create("agt", this);
    dmon = dfi_monitor::type_id::create("dmon", this);
    sb   = hbm_scoreboard::type_id::create("sb", this);
    cov  = hbm_coverage::type_id::create("cov", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    agt.mon.ap_wbeat.connect(sb.imp_wbeat);
    agt.mon.ap_wdone.connect(sb.imp_wdone);
    agt.mon.ap_rdone.connect(sb.imp_rdone);
    dmon.ap.connect(sb.imp_dfi);
    agt.mon.ap_wdone.connect(cov.imp_w);
    agt.mon.ap_rdone.connect(cov.imp_r);
    dmon.ap.connect(cov.imp_d);
    cfg.sb = sb;
  endfunction
endclass
