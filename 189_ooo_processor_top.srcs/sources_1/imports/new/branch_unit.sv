`timescale 1ns / 1ps
import cpu_pkg::*;

module branch_unit (
  input  logic         clk,
  input  logic         reset,
  input  logic         flush_i,

  // Issue interface
  input  logic         valid_i,
  input  rs_pkt_t      pkt_i,
  input  logic [31:0]  src0_data_i,
  input  logic [31:0]  src1_data_i,
  output logic         ready_o,

  // Writeback interface (only for JALR which writes link address)
  output logic         wb_valid_o,
  output logic [31:0]  wb_data_o,
  output logic [6:0]   wb_dst_prf_o,
  output logic [$clog2(ROB_ENTRIES)-1:0] wb_rob_tag_o,
  
  // Completion signal (for all branch instructions including BNE)
  output logic         complete_o,
  output logic [$clog2(ROB_ENTRIES)-1:0] complete_rob_tag_o,
  
  // Branch specific outputs (to ROB/Recovery)
  output logic         br_mispredict_o,
  output logic [31:0]  br_target_o,

  // Branch resolve (to branch predictor update)
  output logic         br_resolve_valid_o,
  output logic [31:0]  br_resolve_pc_o,
  output logic         br_resolve_taken_o,
  output logic         br_resolve_is_jalr_o,
  output logic [31:0]  br_resolve_target_o
);

  // Branch micro_op encoding (from decode_module control signals):
  // micro_op[0] = branch (1: BNE - Branch if Not Equal)
  // micro_op[1] = isJump (1: JALR - Jump and Link Register)
  //
  // When branch=1, isJump=0 -> BNE
  // When branch=0, isJump=1 -> JALR

  assign ready_o = 1'b1; // 1-cycle branch resolution

  // Combinational logic for branch computation
  logic        is_bne;
  logic        is_jalr;
  logic        take_branch;
  logic [31:0] target_addr;
  logic [31:0] link_addr;
  logic        mispredict;
  logic        pred_taken;
  logic [31:0] pred_target;
  logic [31:0] correct_next_pc;
  
  assign is_bne  = pkt_i.micro_op[0];  // branch signal from control_unit
  assign is_jalr = pkt_i.micro_op[1];  // isJump signal from control_unit
  
  always_comb begin
    if (is_jalr) begin
      // JALR: target = (rs1 + imm) & ~1, always taken
      take_branch = 1'b1;
      target_addr = (src0_data_i + pkt_i.imm) & 32'hFFFFFFFE;
      link_addr   = pkt_i.pc + 32'd4; // Return address
      pred_taken    = pkt_i.pred_taken;
      pred_target   = pkt_i.pred_target;
      correct_next_pc = target_addr;
      mispredict    = (pred_taken != take_branch) || (take_branch && (pred_target != target_addr));
    end else begin
      // BNE: target = PC + imm, taken if src0 != src1
      take_branch = (src0_data_i != src1_data_i);
      target_addr = pkt_i.pc + pkt_i.imm;
      link_addr   = 32'b0; // BNE doesn't write to register
      pred_taken    = pkt_i.pred_taken;
      pred_target   = pkt_i.pred_target;
      correct_next_pc = take_branch ? target_addr : (pkt_i.pc + 32'd4);
      mispredict    = (pred_taken != take_branch) || (take_branch && (pred_target != target_addr));
    end
  end

  always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
      wb_valid_o         <= 1'b0;
      wb_data_o          <= '0;
      wb_dst_prf_o       <= '0;
      wb_rob_tag_o       <= '0;
      complete_o         <= 1'b0;
      complete_rob_tag_o <= '0;
      br_mispredict_o    <= 1'b0;
      br_target_o        <= '0;
      br_resolve_valid_o  <= 1'b0;
      br_resolve_pc_o     <= '0;
      br_resolve_taken_o  <= 1'b0;
      br_resolve_is_jalr_o <= 1'b0;
      br_resolve_target_o <= '0;
    end else begin
      // Let all in-flight branches complete, even during recovery
      // During flush, still process valid_i to complete non-speculative branches
      // but suppress mispredict output to avoid multiple recovery triggers
      
      // Completion signal: ALL branch instructions (BNE and JALR) complete
      complete_o         <= valid_i;
      complete_rob_tag_o <= valid_i ? pkt_i.rob_tag : complete_rob_tag_o;
      
      // Writeback signal: ONLY JALR writes to register (link address)
      wb_valid_o <= valid_i && is_jalr;
      if (valid_i) begin
        wb_dst_prf_o    <= pkt_i.dst_prf;
        wb_rob_tag_o    <= pkt_i.rob_tag;
        wb_data_o       <= link_addr;    // JALR writes link address
        br_target_o     <= correct_next_pc;
        // During flush, suppress mispredict to avoid double-recovery
        br_mispredict_o <= mispredict && !flush_i;

        // Predictor update uses the resolved (actual) branch info.
        // During flush/recovery, suppress updates to avoid training on squashed-path ops.
        br_resolve_valid_o   <= !flush_i;
        br_resolve_pc_o      <= pkt_i.pc;
        br_resolve_taken_o   <= take_branch;
        br_resolve_is_jalr_o <= is_jalr;
        br_resolve_target_o  <= target_addr;
      end else begin
        br_mispredict_o <= 1'b0;
        br_resolve_valid_o <= 1'b0;
      end
    end
  end
endmodule