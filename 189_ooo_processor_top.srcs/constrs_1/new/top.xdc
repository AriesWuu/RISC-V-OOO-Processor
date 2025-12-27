
## =============================================================
## PYNQ-Z2 constraints for this project (Vivado 2025.01)
## Top-level ports (from top.sv):
##   input  clk
##   input  reset
##   output [31:0] pc_out
##   output commit_valid_o
## =============================================================

## -----------------------------
## Clock
## - Set the period to match your actual board clock.
## - Target: 50MHz (20ns period)
## -----------------------------
set_property -dict { PACKAGE_PIN H16   IOSTANDARD LVCMOS33 } [get_ports { clk }];
create_clock -name sys_clk_pin -period 20.00 -waveform {0 10.000} [get_ports { clk }];

## -----------------------------
## Reset: map to BTN0 (active-high on most Digilent boards)
## If your design expects active-low reset, invert it in RTL or remap here.
## -----------------------------
set_property -dict { PACKAGE_PIN D19   IOSTANDARD LVCMOS33 } [get_ports { reset }];
set_false_path -from [get_ports { reset }];

## -----------------------------
## Commit valid: map to LED0
## -----------------------------
set_property -dict { PACKAGE_PIN R14   IOSTANDARD LVCMOS33 } [get_ports { commit_valid_o }];

## -----------------------------
## Debug outputs - set false path (LEDs/Pmod don't need strict timing)
## This eliminates timing violations on debug-only output paths
## -----------------------------
set_false_path -to [get_ports { commit_valid_o }]
set_false_path -to [get_ports { pc_out[*] }]

## -----------------------------
## pc_out[31:0] mapping
## - Use on-board LEDs for LSBs
## - Use Arduino header + Pmod for remaining bits
## -----------------------------

## LEDs (3) (LED0 is used by commit_valid_o)
set_property -dict { PACKAGE_PIN P14   IOSTANDARD LVCMOS33 } [get_ports { pc_out[0] }];
set_property -dict { PACKAGE_PIN N16   IOSTANDARD LVCMOS33 } [get_ports { pc_out[1] }];
set_property -dict { PACKAGE_PIN M14   IOSTANDARD LVCMOS33 } [get_ports { pc_out[2] }];

## Arduino digital IO (14): pc_out[3]..pc_out[16]
set_property -dict { PACKAGE_PIN T14   IOSTANDARD LVCMOS33 } [get_ports { pc_out[3] }];  # Sch=ar[0]
set_property -dict { PACKAGE_PIN U12   IOSTANDARD LVCMOS33 } [get_ports { pc_out[4] }];  # Sch=ar[1]
set_property -dict { PACKAGE_PIN U13   IOSTANDARD LVCMOS33 } [get_ports { pc_out[5] }];  # Sch=ar[2]
set_property -dict { PACKAGE_PIN V13   IOSTANDARD LVCMOS33 } [get_ports { pc_out[6] }];  # Sch=ar[3]
set_property -dict { PACKAGE_PIN V15   IOSTANDARD LVCMOS33 } [get_ports { pc_out[7] }];  # Sch=ar[4]
set_property -dict { PACKAGE_PIN T15   IOSTANDARD LVCMOS33 } [get_ports { pc_out[8] }];  # Sch=ar[5]
set_property -dict { PACKAGE_PIN R16   IOSTANDARD LVCMOS33 } [get_ports { pc_out[9] }];  # Sch=ar[6]
set_property -dict { PACKAGE_PIN U17   IOSTANDARD LVCMOS33 } [get_ports { pc_out[10] }]; # Sch=ar[7]
set_property -dict { PACKAGE_PIN V17   IOSTANDARD LVCMOS33 } [get_ports { pc_out[11] }]; # Sch=ar[8]
set_property -dict { PACKAGE_PIN V18   IOSTANDARD LVCMOS33 } [get_ports { pc_out[12] }]; # Sch=ar[9]
set_property -dict { PACKAGE_PIN T16   IOSTANDARD LVCMOS33 } [get_ports { pc_out[13] }]; # Sch=ar[10]
set_property -dict { PACKAGE_PIN R17   IOSTANDARD LVCMOS33 } [get_ports { pc_out[14] }]; # Sch=ar[11]
set_property -dict { PACKAGE_PIN P18   IOSTANDARD LVCMOS33 } [get_ports { pc_out[15] }]; # Sch=ar[12]
set_property -dict { PACKAGE_PIN N17   IOSTANDARD LVCMOS33 } [get_ports { pc_out[16] }]; # Sch=ar[13]

## PmodA (8): pc_out[17]..pc_out[24]
set_property -dict { PACKAGE_PIN Y18   IOSTANDARD LVCMOS33 } [get_ports { pc_out[17] }]; # Sch=ja_p[1]
set_property -dict { PACKAGE_PIN Y19   IOSTANDARD LVCMOS33 } [get_ports { pc_out[18] }]; # Sch=ja_n[1]
set_property -dict { PACKAGE_PIN Y16   IOSTANDARD LVCMOS33 } [get_ports { pc_out[19] }]; # Sch=ja_p[2]
set_property -dict { PACKAGE_PIN Y17   IOSTANDARD LVCMOS33 } [get_ports { pc_out[20] }]; # Sch=ja_n[2]
set_property -dict { PACKAGE_PIN U18   IOSTANDARD LVCMOS33 } [get_ports { pc_out[21] }]; # Sch=ja_p[3]
set_property -dict { PACKAGE_PIN U19   IOSTANDARD LVCMOS33 } [get_ports { pc_out[22] }]; # Sch=ja_n[3]
set_property -dict { PACKAGE_PIN W18   IOSTANDARD LVCMOS33 } [get_ports { pc_out[23] }]; # Sch=ja_p[4]
set_property -dict { PACKAGE_PIN W19   IOSTANDARD LVCMOS33 } [get_ports { pc_out[24] }]; # Sch=ja_n[4]

## PmodB (7): pc_out[25]..pc_out[31]
set_property -dict { PACKAGE_PIN W14   IOSTANDARD LVCMOS33 } [get_ports { pc_out[25] }]; # Sch=jb_p[1]
set_property -dict { PACKAGE_PIN Y14   IOSTANDARD LVCMOS33 } [get_ports { pc_out[26] }]; # Sch=jb_n[1]
set_property -dict { PACKAGE_PIN T11   IOSTANDARD LVCMOS33 } [get_ports { pc_out[27] }]; # Sch=jb_p[2]
set_property -dict { PACKAGE_PIN T10   IOSTANDARD LVCMOS33 } [get_ports { pc_out[28] }]; # Sch=jb_n[2]
set_property -dict { PACKAGE_PIN V16   IOSTANDARD LVCMOS33 } [get_ports { pc_out[29] }]; # Sch=jb_p[3]
set_property -dict { PACKAGE_PIN W16   IOSTANDARD LVCMOS33 } [get_ports { pc_out[30] }]; # Sch=jb_n[3]
set_property -dict { PACKAGE_PIN V12   IOSTANDARD LVCMOS33 } [get_ports { pc_out[31] }]; # Sch=jb_p[4]

## =============================================================
## TIMING OPTIMIZATION CONSTRAINTS
## =============================================================

## -----------------------------
## Minimal, warning-free timing hints
## Notes:
## - XDC is not the right place for run-level settings (e.g. [get_runs]); keep those in project/run Tcl.
## - Guard constraints so missing hierarchy doesn't emit "set_property expects at least one object".
## -----------------------------

set_property MAX_FANOUT 16 [get_cells -hierarchical -filter {NAME =~ "*u_prf*busy*"}]
