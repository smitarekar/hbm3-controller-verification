/* Minimal generic uvm_hdl backdoor-access backend for use with Verilator.
 * Accellera's uvm-core only ships vendor backends for VCS/Questa/Xcelium
 * (uvm_hdl.c #errors out otherwise). Verilator has no equivalent
 * signal-by-path DPI facility, so this stub reports every path as "not
 * found". Safe because this testbench never calls uvm_hdl_force,
 * uvm_hdl_deposit or register backdoor access. Same stub as
 * axi4-crossbar/tb/uvm_setup.
 */
#include "vpi_user.h"

int uvm_hdl_check_path(char *path) {
  (void)path;
  return 0; /* not found */
}

int uvm_hdl_read(char *path, p_vpi_vecval value) {
  (void)path;
  (void)value;
  return 0; /* failure */
}

int uvm_hdl_deposit(char *path, p_vpi_vecval value) {
  (void)path;
  (void)value;
  return 0; /* failure */
}
