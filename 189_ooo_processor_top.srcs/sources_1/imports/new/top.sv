`timescale 1ns / 1ps
import cpu_pkg::*;

module top #(
  parameter int    PHYS_REGS   = 128,
  parameter int    ROB_ENTRIES = 16,
  parameter int    WORDS       = 512,
  parameter string MEMFILE     = "25instMem-r.mem"
)(
  input  logic        clk,
  input  logic        reset,
  // Outputs for observation (e.g., for testbenches)
  output logic [31:0] pc_out,
  output logic        commit_valid_o
);

  // ============================================================
  // Local parameters
  // ============================================================
  localparam int PRF_BITS = $clog2(PHYS_REGS);
  localparam int ROB_BITS = $clog2(ROB_ENTRIES);

  // ============================================================
  // Branch misprediction and recovery signals
  // ============================================================
  logic        branch_mispredict;
  logic [31:0] branch_target;
  logic [ROB_BITS-1:0] mispredict_rob_tag;  // ROB tag of mispredicting branch

  // ============================================================
  // Branch prediction (8-entry fully associative BTB + 2-bit BHT)
  // ============================================================
  logic        bp_pred_hit_fetch;
  logic        bp_pred_taken_fetch;
  logic [31:0] bp_pred_target_fetch;

  logic        bp_update_valid;
  logic [31:0] bp_update_pc;
  logic        bp_update_taken;
  logic        bp_update_is_jalr;
  logic [31:0] bp_update_target;

  // ============================================================
  // STAGE 1: FETCH
  // ============================================================
  logic [31:0] pc_fetch;
  logic [31:0] instr_fetch;
  logic        valid_fetch;
  logic        ready_out_fetch;

  fetch_module #(
    .WORDS   (WORDS),
    .MEMFILE (MEMFILE)
  ) u_fetch (
    .clk       (clk),
    .reset     (reset),
    .pc_src    (branch_mispredict),
    .pc_branch (branch_target),
    .pred_taken_i (bp_pred_taken_fetch),
    .pred_target_i(bp_pred_target_fetch),
    .ready_out (ready_out_fetch),
    .valid_in  (valid_fetch),
    .pc        (pc_fetch),
    .instr     (instr_fetch)
  );

  branch_predictor #(
    .ENTRIES(8)
  ) u_bp (
    .clk            (clk),
    .reset          (reset),
    .fetch_pc_i     (pc_fetch),
    .pred_hit_o     (bp_pred_hit_fetch),
    .pred_taken_o   (bp_pred_taken_fetch),
    .pred_target_o  (bp_pred_target_fetch),
    .update_valid_i (bp_update_valid),
    .update_pc_i    (bp_update_pc),
    .update_taken_i (bp_update_taken),
    .update_is_jalr_i(bp_update_is_jalr),
    .update_target_i(bp_update_target)
  );

  // ============================================================
  // Skid Buffer: Fetch -> Decode
  // ============================================================
  logic        valid_fetch_to_decode;
  logic        ready_decode_to_fetch;
  logic [31:0] pc_decode;
  logic [31:0] instr_decode;

  logic        pred_hit_decode;
  logic        pred_taken_decode;
  logic [31:0] pred_target_decode;

  pipeline_skid_buffer_struct #(
    .T(logic [97:0])
  ) u_skid_fetch_decode (
    .clk       (clk),
    .reset     (reset),
    .flush     (branch_mispredict),
    .valid_in  (valid_fetch),
    .ready_in  (ready_out_fetch),
    .data_in   ({pc_fetch, instr_fetch, bp_pred_hit_fetch, bp_pred_taken_fetch, bp_pred_target_fetch}),
    .valid_out (valid_fetch_to_decode),
    .ready_out (ready_decode_to_fetch),
    .data_out  ({pc_decode, instr_decode, pred_hit_decode, pred_taken_decode, pred_target_decode})
  );

  // ============================================================
  // STAGE 2: DECODE
  // ============================================================
  logic [4:0]  srcReg1_decode, srcReg2_decode, destReg_decode;
  logic [31:0] imm_decode;
  logic        hasImm_decode;
  logic [1:0]  fu_decode;
  logic        regWrite_decode, aluSrc_decode;
  logic        branch_decode, isJump_decode;
  logic        loadByte_decode, storeHalf_decode;
  logic        memRead_decode, memWrite_decode, memToReg_decode;
  logic [3:0]  alu_ctrl_decode;

  decode_module u_decode (
    .clk       (clk),
    .reset     (reset),
    .instr     (instr_decode),
    .srcReg1   (srcReg1_decode),
    .srcReg2   (srcReg2_decode),
    .destReg   (destReg_decode),
    .imm       (imm_decode),
    .hasImm    (hasImm_decode),
    .fu        (fu_decode),
    .regWrite  (regWrite_decode),
    .aluSrc    (aluSrc_decode),
    .branch    (branch_decode),
    .isJump    (isJump_decode),
    .loadByte  (loadByte_decode),
    .storeHalf (storeHalf_decode),
    .memRead   (memRead_decode),
    .memWrite  (memWrite_decode),
    .memToReg  (memToReg_decode),
    .alu_ctrl  (alu_ctrl_decode)
  );

  // ============================================================
  // Skid Buffer: Decode -> Rename
  // ============================================================
  logic        valid_decode_to_rename;
  logic        ready_rename_to_decode;
  decode_pkt_t decode_pkt_in, decode_pkt_out;

  // Pack decode outputs into struct
  assign decode_pkt_in.pc        = pc_decode;
  assign decode_pkt_in.pred_hit  = pred_hit_decode;
  assign decode_pkt_in.pred_taken= pred_taken_decode;
  assign decode_pkt_in.pred_target = pred_target_decode;
  assign decode_pkt_in.srcReg1   = srcReg1_decode;
  assign decode_pkt_in.srcReg2   = srcReg2_decode;
  assign decode_pkt_in.destReg   = destReg_decode;
  assign decode_pkt_in.imm       = imm_decode;
  assign decode_pkt_in.fu        = fu_decode;
  assign decode_pkt_in.regWrite  = regWrite_decode;
  assign decode_pkt_in.aluSrc    = aluSrc_decode;
  assign decode_pkt_in.branch    = branch_decode;
  assign decode_pkt_in.isJump    = isJump_decode;
  assign decode_pkt_in.memRead   = memRead_decode;
  assign decode_pkt_in.memWrite  = memWrite_decode;
  assign decode_pkt_in.loadByte  = loadByte_decode;
  assign decode_pkt_in.storeHalf = storeHalf_decode;
  assign decode_pkt_in.alu_ctrl  = alu_ctrl_decode;

  pipeline_skid_buffer_struct #(
    .T(decode_pkt_t)
  ) u_skid_decode_rename (
    .clk       (clk),
    .reset     (reset),
    .flush     (branch_mispredict),
    .valid_in  (valid_fetch_to_decode),
    .ready_in  (ready_decode_to_fetch),
    .data_in   (decode_pkt_in),
    .valid_out (valid_decode_to_rename),
    .ready_out (ready_rename_to_decode),
    .data_out  (decode_pkt_out)
  );

  // Alias decode packet fields for rename stage
  wire [31:0] pc_rename        = decode_pkt_out.pc;
  wire        pred_hit_rename  = decode_pkt_out.pred_hit;
  wire        pred_taken_rename = decode_pkt_out.pred_taken;
  wire [31:0] pred_target_rename = decode_pkt_out.pred_target;
  wire [4:0]  srcReg1_rename   = decode_pkt_out.srcReg1;
  wire [4:0]  srcReg2_rename   = decode_pkt_out.srcReg2;
  wire [4:0]  destReg_rename   = decode_pkt_out.destReg;
  wire [31:0] imm_rename       = decode_pkt_out.imm;
  wire [1:0]  fu_rename        = decode_pkt_out.fu;
  wire        regWrite_rename  = decode_pkt_out.regWrite;
  wire        aluSrc_rename    = decode_pkt_out.aluSrc;
  wire        branch_rename    = decode_pkt_out.branch;
  wire        isJump_rename    = decode_pkt_out.isJump;
  wire        memRead_rename   = decode_pkt_out.memRead;
  wire        memWrite_rename  = decode_pkt_out.memWrite;
  wire        loadByte_rename  = decode_pkt_out.loadByte;
  wire        storeHalf_rename = decode_pkt_out.storeHalf;
  wire [3:0]  alu_ctrl_rename  = decode_pkt_out.alu_ctrl;

  // ============================================================
  // STAGE 3: RENAME
  // ============================================================
  logic        valid_rename_to_dispatch;
  logic        ready_dispatch_to_rename;
  logic [6:0]  srcReg1_phys, srcReg2_phys, destReg_phys, oldDest_phys;
  logic [ROB_BITS-1:0] rob_tag_rename;
  logic [6:0]  micro_op_rename;
  logic [1:0]  fu_rename_out;
  logic        is_branch_rename_out, writes_rd_rename_out;
  logic [31:0] imm_rename_out, pc_rename_out;
  logic        pred_hit_rename_out, pred_taken_rename_out;
  logic [31:0] pred_target_rename_out;

  // Commit signals from ROB (for retire)
  logic        commit_valid;
  logic        commit_writes_rd;
  logic [6:0]  commit_dst_old;

  rename_module #(
    .ARCH_REGS   (32),
    .PHYS_REGS   (PHYS_REGS),
    .ROB_ENTRIES (ROB_ENTRIES)
  ) u_rename (
    .clk                 (clk),
    .reset               (reset),
    // From decode skid buffer
    .ready_from_dispatch (ready_dispatch_to_rename),
    .valid_from_decode   (valid_decode_to_rename),
    .srcReg1_arch        (srcReg1_rename),
    .srcReg2_arch        (srcReg2_rename),
    .destReg_arch        (destReg_rename),
    .regWrite_rename     (regWrite_rename),
    .branch_rename       (branch_rename),
    // Control signals from decode
    .fu_i                (fu_rename),
    .alu_ctrl_i          (alu_ctrl_rename),
    .aluSrc_i            (aluSrc_rename),
    .isJump_i            (isJump_rename),
    .memRead_i           (memRead_rename),
    .memWrite_i          (memWrite_rename),
    .loadByte_i          (loadByte_rename),
    .storeHalf_i         (storeHalf_rename),
    .imm_i               (imm_rename),
    .pc_i                (pc_rename),
    .pred_hit_i          (pred_hit_rename),
    .pred_taken_i        (pred_taken_rename),
    .pred_target_i       (pred_target_rename),
    // Branch misprediction recovery
    .branch_miss_rename  (branch_mispredict),
    .recover_tag_i       (mispredict_rob_tag),  // ROB tag of mispredicting branch
    // Retire signals from ROB commit
    .retire_enable       (commit_valid && commit_writes_rd),
    .retired_destReg_phys(commit_dst_old),
    // Outputs to dispatch
    .valid_to_dispatch   (valid_rename_to_dispatch),
    .ready_to_decode     (ready_rename_to_decode),
    .srcReg1_phys        (srcReg1_phys),
    .srcReg2_phys        (srcReg2_phys),
    .destReg_phys        (destReg_phys),
    .oldDest_phys        (oldDest_phys),
    .rob_tag             (rob_tag_rename),
    // Packed outputs
    .micro_op_o          (micro_op_rename),
    .fu_o                (fu_rename_out),
    .is_branch_o         (is_branch_rename_out),
    .writes_rd_o         (writes_rd_rename_out),
    .imm_o               (imm_rename_out),
    .pc_o                (pc_rename_out),
    .pred_hit_o          (pred_hit_rename_out),
    .pred_taken_o        (pred_taken_rename_out),
    .pred_target_o       (pred_target_rename_out)
  );

  // ============================================================
  // STAGE 4: DISPATCH (includes RS, ROB, PRF)
  // ============================================================
  // Issue packets and data from dispatch to execution units
  logic        alu_issue_valid, br_issue_valid, lsu_issue_valid;
  rs_pkt_t     alu_issue_pkt, br_issue_pkt, lsu_issue_pkt;
  logic [31:0] alu_src0_data, alu_src1_data;
  logic [31:0] br_src0_data, br_src1_data;
  logic [31:0] lsu_src0_data, lsu_src1_data;

  // Writeback signals from execution units
  logic        wb_alu_valid, wb_br_valid, wb_lsu_valid;
  logic [6:0]  wb_alu_prf, wb_br_prf, wb_lsu_prf;
  logic [31:0] wb_alu_data, wb_br_data, wb_lsu_data;
  logic [ROB_BITS-1:0] wb_alu_rob_tag, wb_br_rob_tag, wb_lsu_rob_tag;

  // EXU ready signals - forward declarations (assigned after execution units)
  logic alu_ready, br_ready, lsu_ready;

  // Branch completion signals (separate from writeback - BNE completes but doesn't write)
  logic        complete_br_valid;
  logic [ROB_BITS-1:0] complete_br_rob_tag;

  dispatch_module #(
    .PHYS_REGS    (PHYS_REGS),
    .ALU_RS_DEPTH (8),
    .BR_RS_DEPTH  (8),
    .LSU_RS_DEPTH (8),
    .ROB_DEPTH    (ROB_ENTRIES)
  ) u_dispatch (
    .clk              (clk),
    .reset            (reset),
    .recover_i        (branch_mispredict),
    // From rename
    .rn_valid_i       (valid_rename_to_dispatch),
    .rn_ready_o       (ready_dispatch_to_rename),
    .rn_micro_op_i    (micro_op_rename),
    .rn_dst_prf_new_i (destReg_phys),
    .rn_dst_prf_old_i (oldDest_phys),
    .rn_src0_prf_i    (srcReg1_phys),
    .rn_src1_prf_i    (srcReg2_phys),
    .rn_imm_i         (imm_rename_out),
    .rn_fu_i          (fu_rename_out),
    .rn_is_branch_i   (is_branch_rename_out),
    .rn_writes_rd_i   (writes_rd_rename_out),
    .rn_rob_tag_i     (rob_tag_rename),
    .rn_pc_i          (pc_rename_out),
    .rn_pred_hit_i    (pred_hit_rename_out),
    .rn_pred_taken_i  (pred_taken_rename_out),
    .rn_pred_target_i (pred_target_rename_out),
    // EXU ready
    .alu_exu_ready_i  (alu_ready),
    .br_exu_ready_i   (br_ready),
    .lsu_exu_ready_i  (lsu_ready),
    // Issue outputs
    .alu_issue_valid_o(alu_issue_valid),
    .alu_issue_pkt_o  (alu_issue_pkt),
    .alu_src0_data_o  (alu_src0_data),
    .alu_src1_data_o  (alu_src1_data),
    .br_issue_valid_o (br_issue_valid),
    .br_issue_pkt_o   (br_issue_pkt),
    .br_src0_data_o   (br_src0_data),
    .br_src1_data_o   (br_src1_data),
    .lsu_issue_valid_o(lsu_issue_valid),
    .lsu_issue_pkt_o  (lsu_issue_pkt),
    .lsu_src0_data_o  (lsu_src0_data),
    .lsu_src1_data_o  (lsu_src1_data),
    // Writeback inputs
    .wb_alu_valid_i   (wb_alu_valid),
    .wb_alu_prf_i     (wb_alu_prf),
    .wb_alu_data_i    (wb_alu_data),
    .wb_br_valid_i    (wb_br_valid),
    .wb_br_prf_i      (wb_br_prf),
    .wb_br_data_i     (wb_br_data),
    .wb_lsu_valid_i   (wb_lsu_valid),
    .wb_lsu_prf_i     (wb_lsu_prf),
    .wb_lsu_data_i    (wb_lsu_data),
    // ROB tags from writeback
    .wb_alu_rob_tag_i (wb_alu_rob_tag),
    .wb_br_rob_tag_i  (wb_br_rob_tag),
    .wb_lsu_rob_tag_i (wb_lsu_rob_tag),
    // Branch completion (separate from writeback - BNE completes but doesn't write)
    .complete_br_valid_i   (complete_br_valid),
    .complete_br_rob_tag_i (complete_br_rob_tag),
    // Commit outputs
    .commit_valid_o   (commit_valid),
    .commit_writes_rd_o(commit_writes_rd),
    .commit_dst_old_o (commit_dst_old)
  );

  // ============================================================
  // EXECUTION UNITS
  // ============================================================
  
  // ----- ALU Unit -----
  ALU_unit u_alu (
    .clk          (clk),
    .reset        (reset),
    .flush_i      (branch_mispredict),
    .valid_i      (alu_issue_valid),
    .pkt_i        (alu_issue_pkt),
    .src0_data_i  (alu_src0_data),
    .src1_data_i  (alu_src1_data),
    .ready_o      (alu_ready),
    .wb_valid_o   (wb_alu_valid),
    .wb_data_o    (wb_alu_data),
    .wb_dst_prf_o (wb_alu_prf),
    .wb_rob_tag_o (wb_alu_rob_tag)
  );

  // ----- Branch Unit -----
  branch_unit u_branch (
    .clk                (clk),
    .reset              (reset),
    .flush_i            (branch_mispredict),
    .valid_i            (br_issue_valid),
    .pkt_i              (br_issue_pkt),
    .src0_data_i        (br_src0_data),
    .src1_data_i        (br_src1_data),
    .ready_o            (br_ready),
    .wb_valid_o         (wb_br_valid),
    .wb_data_o          (wb_br_data),
    .wb_dst_prf_o       (wb_br_prf),
    .wb_rob_tag_o       (wb_br_rob_tag),
    .complete_o         (complete_br_valid),
    .complete_rob_tag_o (complete_br_rob_tag),
    .br_mispredict_o    (branch_mispredict),
    .br_target_o        (branch_target),
    .br_resolve_valid_o (bp_update_valid),
    .br_resolve_pc_o    (bp_update_pc),
    .br_resolve_taken_o (bp_update_taken),
    .br_resolve_is_jalr_o(bp_update_is_jalr),
    .br_resolve_target_o(bp_update_target)
  );
  
  // Connect mispredict_rob_tag from branch unit's writeback
  assign mispredict_rob_tag = wb_br_rob_tag;

  // ----- LSU Unit -----
  logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
  logic        dmem_re;
  logic [3:0]  dmem_we;

  LSU_unit u_lsu (
    .clk          (clk),
    .reset        (reset),
    .flush_i      (branch_mispredict),
    .valid_i      (lsu_issue_valid),
    .pkt_i        (lsu_issue_pkt),
    .src0_data_i  (lsu_src0_data),
    .src1_data_i  (lsu_src1_data),
    .ready_o      (lsu_ready),
    .wb_valid_o   (wb_lsu_valid),
    .wb_data_o    (wb_lsu_data),
    .wb_dst_prf_o (wb_lsu_prf),
    .wb_rob_tag_o (wb_lsu_rob_tag),
    .dmem_addr_o  (dmem_addr),
    .dmem_re_o    (dmem_re),
    .dmem_we_o    (dmem_we),
    .dmem_wdata_o (dmem_wdata),
    .dmem_rdata_i (dmem_rdata)
  );

  // ============================================================
  // DATA MEMORY
  // ============================================================
  data_memory #(
    .WORDS(131072) // 512KB memory
  ) u_dmem (
    .clk   (clk),
    .re    (dmem_re),
    .we    (dmem_we),
    .addr  (dmem_addr),
    .wdata (dmem_wdata),
    .rdata (dmem_rdata)
  );

  // ============================================================
  // Output Assignments
  // ============================================================
  assign pc_out = pc_fetch;
  assign commit_valid_o = commit_valid;

endmodule