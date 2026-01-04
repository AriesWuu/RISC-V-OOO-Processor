`timescale 1ns / 1ps

// Physical Register File with REPLICATED busy scoreboard for timing optimization
// Each RS gets its own copy of the busy vector to reduce fanout
module PRF #(
  parameter int PHYS_REGS = 128
)(
  input  logic clk,
  input  logic reset,
  // writeback, multiple ports (ALU0, ALU1, Branch, LSU)
  input  logic        wb_alu_en_i,
  input  logic [6:0]  wb_alu_preg_i,
  input  logic [31:0] wb_alu_data_i,

  // Second ALU writeback port
  input  logic        wb_alu1_en_i,
  input  logic [6:0]  wb_alu1_preg_i,
  input  logic [31:0] wb_alu1_data_i,

  input  logic        wb_br_en_i,
  input  logic [6:0]  wb_br_preg_i,
  input  logic [31:0] wb_br_data_i,

  input  logic        wb_lsu_en_i,
  input  logic [6:0]  wb_lsu_preg_i,
  input  logic [31:0] wb_lsu_data_i,

  // busy scoreboard control (dual set_busy for dual-dispatch)
  input  logic        set_busy_en_0_i,
  input  logic [6:0]  set_busy_preg_0_i,
  input  logic        set_busy_en_1_i,
  input  logic [6:0]  set_busy_preg_1_i,
  input  logic        clr_busy_en_i,
  input  logic [6:0]  clr_busy_preg_i,

  // Replicated busy outputs for each RS (reduces fanout from 48 to 16 per copy)
  output logic [PHYS_REGS-1:0] busy_o,       // For ALU RS (shared by both ALU0 and ALU1)
  output logic [PHYS_REGS-1:0] busy_br_o,    // For Branch RS
  output logic [PHYS_REGS-1:0] busy_lsu_o,   // For LSU RS

  // four-way issue read ports (2 reads per way) - ALU0, ALU1, Branch, LSU
  input  logic        iss0_valid_i,
  input  logic [6:0]  iss0_src0_i, iss0_src1_i,
  output logic [31:0] iss0_r0_o, iss0_r1_o,

  input  logic        iss1_valid_i,
  input  logic [6:0]  iss1_src0_i, iss1_src1_i,
  output logic [31:0] iss1_r0_o, iss1_r1_o,

  input  logic        iss2_valid_i,
  input  logic [6:0]  iss2_src0_i, iss2_src1_i,
  output logic [31:0] iss2_r0_o, iss2_r1_o,

  // Fourth issue port for ALU1
  input  logic        iss3_valid_i,
  input  logic [6:0]  iss3_src0_i, iss3_src1_i,
  output logic [31:0] iss3_r0_o, iss3_r1_o
);
  logic [31:0] rf[PHYS_REGS];
  
  // Replicated busy registers - same update logic, separate physical registers
  // This forces Vivado to create 3 copies, reducing fanout per register
  (* DONT_TOUCH = "yes" *) logic [PHYS_REGS-1:0] busy_alu;
  (* DONT_TOUCH = "yes" *) logic [PHYS_REGS-1:0] busy_br;
  (* DONT_TOUCH = "yes" *) logic [PHYS_REGS-1:0] busy_lsu;

  assign busy_o     = busy_alu;
  assign busy_br_o  = busy_br;
  assign busy_lsu_o = busy_lsu;

  // ============================================================
  // Read ports (combinational, NO bypass)
  // ============================================================
  assign iss0_r0_o = rf[iss0_src0_i];
  assign iss0_r1_o = rf[iss0_src1_i];
  assign iss1_r0_o = rf[iss1_src0_i];
  assign iss1_r1_o = rf[iss1_src1_i];
  assign iss2_r0_o = rf[iss2_src0_i];
  assign iss2_r1_o = rf[iss2_src1_i];
  assign iss3_r0_o = rf[iss3_src0_i];
  assign iss3_r1_o = rf[iss3_src1_i];

  // ============================================================
  // Unified update logic for all busy copies
  // ============================================================
  logic [7:0] i;
  always_ff @(posedge clk or posedge reset) begin
    if(reset) begin
      for (i=0;i<PHYS_REGS;i++) begin
        rf[i]       <= '0;
        busy_alu[i] <= 1'b0;
        busy_br[i]  <= 1'b0;
        busy_lsu[i] <= 1'b0;
      end
    end else begin
      // Writeback ports - update RF and clear busy in all copies
      if (wb_alu_en_i && wb_alu_preg_i != 7'd0) begin
        rf[wb_alu_preg_i]       <= wb_alu_data_i;
        busy_alu[wb_alu_preg_i] <= 1'b0;
        busy_br[wb_alu_preg_i]  <= 1'b0;
        busy_lsu[wb_alu_preg_i] <= 1'b0;
      end
      if (wb_alu1_en_i && wb_alu1_preg_i != 7'd0) begin
        rf[wb_alu1_preg_i]       <= wb_alu1_data_i;
        busy_alu[wb_alu1_preg_i] <= 1'b0;
        busy_br[wb_alu1_preg_i]  <= 1'b0;
        busy_lsu[wb_alu1_preg_i] <= 1'b0;
      end
      if (wb_br_en_i && wb_br_preg_i != 7'd0) begin
        rf[wb_br_preg_i]       <= wb_br_data_i;
        busy_alu[wb_br_preg_i] <= 1'b0;
        busy_br[wb_br_preg_i]  <= 1'b0;
        busy_lsu[wb_br_preg_i] <= 1'b0;
      end
      if (wb_lsu_en_i && wb_lsu_preg_i != 7'd0) begin
        rf[wb_lsu_preg_i]       <= wb_lsu_data_i;
        busy_alu[wb_lsu_preg_i] <= 1'b0;
        busy_br[wb_lsu_preg_i]  <= 1'b0;
        busy_lsu[wb_lsu_preg_i] <= 1'b0;
      end

      // Dual set busy ports - update all copies
      if (set_busy_en_0_i && set_busy_preg_0_i != 7'd0) begin
        busy_alu[set_busy_preg_0_i] <= 1'b1;
        busy_br[set_busy_preg_0_i]  <= 1'b1;
        busy_lsu[set_busy_preg_0_i] <= 1'b1;
      end

      if (set_busy_en_1_i && set_busy_preg_1_i != 7'd0) begin
        busy_alu[set_busy_preg_1_i] <= 1'b1;
        busy_br[set_busy_preg_1_i]  <= 1'b1;
        busy_lsu[set_busy_preg_1_i] <= 1'b1;
      end

      // Explicit clear busy - update all copies
      if (clr_busy_en_i && clr_busy_preg_i != 7'd0) begin
        busy_alu[clr_busy_preg_i] <= 1'b0;
        busy_br[clr_busy_preg_i]  <= 1'b0;
        busy_lsu[clr_busy_preg_i] <= 1'b0;
      end
    end
  end
endmodule