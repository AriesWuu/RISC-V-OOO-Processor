`timescale 1ns / 1ps

module PRF #(
  parameter int PHYS_REGS = 128
)(
  input  logic clk,
  input  logic reset,
  // writeback, multiple ports (ALU, Branch, LSU)
  input  logic        wb_alu_en_i,
  input  logic [6:0]  wb_alu_preg_i,
  input  logic [31:0] wb_alu_data_i,

  input  logic        wb_br_en_i,
  input  logic [6:0]  wb_br_preg_i,
  input  logic [31:0] wb_br_data_i,

  input  logic        wb_lsu_en_i,
  input  logic [6:0]  wb_lsu_preg_i,
  input  logic [31:0] wb_lsu_data_i,

  // busy scoreboard control
  input  logic        set_busy_en_i,
  input  logic [6:0]  set_busy_preg_i,
  input  logic        clr_busy_en_i,
  input  logic [6:0]  clr_busy_preg_i,
  output logic [PHYS_REGS-1:0] busy_o,

  // three-way issue read ports (2 reads per way)
  input  logic        iss0_valid_i,
  input  logic [6:0]  iss0_src0_i, iss0_src1_i,
  output logic [31:0] iss0_r0_o, iss0_r1_o,

  input  logic        iss1_valid_i,
  input  logic [6:0]  iss1_src0_i, iss1_src1_i,
  output logic [31:0] iss1_r0_o, iss1_r1_o,

  input  logic        iss2_valid_i,
  input  logic [6:0]  iss2_src0_i, iss2_src1_i,
  output logic [31:0] iss2_r0_o, iss2_r1_o
);
  logic [31:0] rf[PHYS_REGS];
  logic [PHYS_REGS-1:0] busy;

  assign busy_o = busy;

  // ============================================================
  // Bypass/Forwarding Logic for same-cycle read-after-write
  // ============================================================
  // Helper function to select data with bypass
  function automatic logic [31:0] read_with_bypass(
    input logic [6:0] addr,
    input logic [31:0] rf_data
  );
    // Check if any writeback is targeting this address in the same cycle
    if (wb_alu_en_i && wb_alu_preg_i == addr && addr != 7'd0)
      return wb_alu_data_i;
    else if (wb_br_en_i && wb_br_preg_i == addr && addr != 7'd0)
      return wb_br_data_i;
    else if (wb_lsu_en_i && wb_lsu_preg_i == addr && addr != 7'd0)
      return wb_lsu_data_i;
    else
      return rf_data;
  endfunction

  // Read ports with bypass (combinational)
  assign iss0_r0_o = read_with_bypass(iss0_src0_i, rf[iss0_src0_i]);
  assign iss0_r1_o = read_with_bypass(iss0_src1_i, rf[iss0_src1_i]);
  assign iss1_r0_o = read_with_bypass(iss1_src0_i, rf[iss1_src0_i]);
  assign iss1_r1_o = read_with_bypass(iss1_src1_i, rf[iss1_src1_i]);
  assign iss2_r0_o = read_with_bypass(iss2_src0_i, rf[iss2_src0_i]);
  assign iss2_r1_o = read_with_bypass(iss2_src1_i, rf[iss2_src1_i]);

  logic [7:0] i;
  always_ff @(posedge clk or posedge reset) begin
    if(reset) begin
      for (i=0;i<PHYS_REGS;i++) begin
        rf[i]   <= '0;
        busy[i] <= 1'b0;
      end
    end else begin
      // Writeback ports
      if (wb_alu_en_i && wb_alu_preg_i != 7'd0) begin
        rf[wb_alu_preg_i]   <= wb_alu_data_i;
        busy[wb_alu_preg_i] <= 1'b0;
      end
      if (wb_br_en_i && wb_br_preg_i != 7'd0) begin
        rf[wb_br_preg_i]   <= wb_br_data_i;
        busy[wb_br_preg_i] <= 1'b0;
      end
      if (wb_lsu_en_i && wb_lsu_preg_i != 7'd0) begin
        rf[wb_lsu_preg_i]   <= wb_lsu_data_i;
        busy[wb_lsu_preg_i] <= 1'b0;
      end

      // Set busy
      if (set_busy_en_i && set_busy_preg_i != 7'd0) busy[set_busy_preg_i] <= 1'b1;
      
      // Explicit clear busy 
      if (clr_busy_en_i && clr_busy_preg_i != 7'd0) busy[clr_busy_preg_i] <= 1'b0;
    end
  end
endmodule