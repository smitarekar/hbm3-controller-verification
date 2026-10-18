#!/usr/bin/env bash
# Unbounded proof of hbm_timing == cycles-since reference, using ABC's PDR.
#
# Runs the same Yosys flow SymbiYosys uses for its abc engine, but calls
# ABC directly (some sby/yosys version pairs crash parsing ABC's result).
#
#   ./run_proof.sh            prove the real harness
#   ./run_proof.sh --sanity   prove a harness with a deliberately wrong
#                             reference (tRCD + 1); this MUST fail, which
#                             shows the proof is not vacuous
set -euo pipefail
cd "$(dirname "$0")"
DUT="${DUT_DIR:-../../hbm3-controller}/rtl"
WORK=build
mkdir -p "$WORK"

HARNESS=timing_equiv.sv
if [ "${1:-}" = "--sanity" ]; then
  sed 's/r_rd\[b\]  = s_act\[b\] >= T_RCD/r_rd[b]  = s_act[b] >= T_RCD + 1/' timing_equiv.sv > "$WORK/neg.sv"
  grep -q "T_RCD + 1" "$WORK/neg.sv"
  HARNESS="$WORK/neg.sv"
fi

sv2v --exclude=Assert "$DUT/hbm_pkg.sv" "$DUT/hbm_timing.sv" "$HARNESS" > "$WORK/flat.v"

yosys -ql "$WORK/yosys.log" 2>>"$WORK/yosys.log" -p "
  read_verilog -sv -formal $WORK/flat.v
  prep -top timing_equiv
  hierarchy -smtcheck
  scc -select; simplemap; select -clear
  memory_nordff
  async2sync
  chformal -assume -early
  opt_clean
  formalff -setundef -clk2ff -ff2anyinit -hierarchy
  chformal -live -fair -cover -remove
  opt_clean
  setundef -undriven -anyseq
  opt -fast
  flatten
  setundef -undriven -anyseq
  opt -full
  techmap
  opt -fast
  memory_map -formal
  formalff -clk2ff -ff2anyinit
  simplemap
  dffunmap
  aigmap
  opt_clean
  stat
  write_aiger -I -B -zinit -no-startoffset $WORK/design.aig
"
RESULT=$(yosys-abc -c "read_aiger $WORK/design.aig; fold; strash; pdr" 2>&1 \
  | sed 's/\x1b\[[0-9;]*m//g' | grep -E "Property|asserted" || true)
echo "$RESULT"
if [ "${1:-}" = "--sanity" ]; then
  if echo "$RESULT" | grep -q asserted; then
    echo "sanity: harness with a wrong tRCD reference is rejected, as it must be"
  else
    echo "sanity: FAILED, the wrong reference was not rejected (proof is vacuous)"; exit 1
  fi
else
  echo "$RESULT" | grep -q "Property proved" || exit 1
  echo "hbm_timing == cycles-since reference: proved for all reachable states (2 BG x 2 banks, scaled timing)"
fi
