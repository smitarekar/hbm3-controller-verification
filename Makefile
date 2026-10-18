# hbm3-controller-verification
#
#   make build                  compile DUT + UVM env (Verilator 5.x)
#   make run TEST=hbm_rand_test SEED=3
#   make regress                every test x SEEDS, merged coverage report
#   make formal                 unbounded proof of the timing engine (sv2v + yosys + abc pdr)
#
# Expects the design repo as a sibling: ../hbm3-controller

VERILATOR ?= verilator
DUT_DIR   ?= ../hbm3-controller
UVM_HOME  ?= .uvm-core
POLICY    ?= 1
ADDR_MAP  ?= 0
TEST      ?= hbm_smoke_test
SEED      ?= 1
SEEDS     ?= 1 2 3
VERB      ?= UVM_LOW
DEFINES   ?=

RTL := $(DUT_DIR)/rtl/hbm_pkg.sv $(DUT_DIR)/rtl/hbm_secded.sv $(DUT_DIR)/rtl/hbm_fifo.sv \
       $(DUT_DIR)/rtl/hbm_timing.sv $(DUT_DIR)/rtl/hbm_refresh.sv $(DUT_DIR)/rtl/hbm_scheduler.sv \
       $(DUT_DIR)/rtl/hbm_axi_fe.sv $(DUT_DIR)/rtl/hbm_rdpath.sv $(DUT_DIR)/rtl/hbm3_ctrl.sv \
       $(DUT_DIR)/model/hbm3_pc_model.sv

TB := tb/hbm_axi_if.sv tb/hbm_phy_if.sv tb/hbm_jedec_sva.sv tb/hbm_axi_sva.sv \
      tb/uvm/hbm_uvm_pkg.sv tb/tb_top.sv

UVM_SRC := $(UVM_HOME)/src/uvm_pkg.sv
UVM_DPI := $(UVM_HOME)/src/dpi/uvm_dpi.cc $(UVM_HOME)/src/dpi/uvm_regex.cc $(UVM_HOME)/src/dpi/uvm_common.c

OBJ ?= sim/obj_p$(POLICY)_m$(ADDR_MAP)
BIN ?= $(OBJ)/sim_uvm

VFLAGS := --binary --timing --vpi --assert --coverage-user -Wno-fatal -Wno-lint -Wno-style \
          -Wno-COVERIGN -Wno-MULTIDRIVEN -Wno-SYMRSVDWORD -Wno-ZERODLY -Wno-CONSTRAINTIGN \
          --timescale 1ns/1ps -j 0 -O2 \
          -GPOLICY=$(POLICY) -GADDR_MAP=$(ADDR_MAP) $(DEFINES)

.PHONY: uvm build run regress formal clean

uvm:
	bash scripts/setup_uvm.sh

build: uvm $(BIN)

$(BIN): $(RTL) $(TB) $(wildcard tb/uvm/*.svh)
	$(VERILATOR) $(VFLAGS) \
	  +incdir+$(UVM_HOME)/src +incdir+tb/uvm \
	  $(UVM_SRC) $(RTL) $(TB) $(UVM_DPI) \
	  -CFLAGS "-I$(UVM_HOME)/src/dpi -Wno-everything -O1" \
	  --top-module tb_top -Mdir $(OBJ) -o sim_uvm

run: build
	@mkdir -p sim/logs sim/cov
	$(BIN) +UVM_TESTNAME=$(TEST) +UVM_VERBOSITY=$(VERB) +verilator+seed+$(SEED) \
	  +verilator+error+limit+20 \
	  +verilator+coverage+file+sim/cov/$(TEST)_s$(SEED).dat 2>&1 | tee sim/logs/$(TEST)_s$(SEED).log

regress: build
	python3 scripts/regress.py --bin $(BIN) --seeds $(SEEDS)

formal:
	DUT_DIR=$(abspath $(DUT_DIR)) bash formal/run_proof.sh
	DUT_DIR=$(abspath $(DUT_DIR)) bash formal/run_proof.sh --sanity

clean:
	rm -rf sim/obj_* sim/logs sim/cov formal/build
