#!/usr/bin/env bash
# Fetches Accellera's uvm-core and applies the three small patches needed
# to link it against Verilator. Same recipe as axi4-crossbar; see the
# comments there for how each patch was derived.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export UVM_HOME="${UVM_HOME:-$REPO_ROOT/.uvm-core}"

if [ -d "$UVM_HOME/src/dpi" ]; then
  echo "uvm-core already present at $UVM_HOME"
  exit 0
fi

git clone --quiet --depth 1 https://github.com/accellera-official/uvm-core.git "$UVM_HOME"
DPI="$UVM_HOME/src/dpi"

# 1. macOS has no <malloc.h>; <stdlib.h> already covers it.
perl -0777 -pi -e 's/#include <malloc\.h>\n//' "$DPI/uvm_dpi.h"

# 2. uvm_common.c needs svdpi.h and limits.h, and an extern "C" wrapper so
#    its declaration matches Verilator's generated C++ export.
perl -0777 -pi -e '
  s/(\/\/ Implementation of common methods for DPI\n)/$1\n#include "svdpi.h"\n#include <limits.h>\n/;
  s/(extern void m__uvm_report_dpi\(int,const char\*,const char\*,int,const char\*, int\);)/#ifdef __cplusplus\nextern "C" {\n#endif\n$1\n#ifdef __cplusplus\n}\n#endif/;
' "$DPI/uvm_common.c"

# 3. Generic backdoor stub in place of the vendor-only backends.
cp "$(dirname "${BASH_SOURCE[0]}")/uvm_hdl_verilator.c" "$DPI/uvm_hdl_verilator.c"
perl -0777 -pi -e 's/#error "hdl vendor backend is missing"/#include "uvm_hdl_verilator.c"/' "$DPI/uvm_hdl.c"

echo "uvm-core ready at $UVM_HOME (patched for Verilator)"
