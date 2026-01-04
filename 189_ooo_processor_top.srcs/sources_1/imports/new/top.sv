`timescale 1ns / 1ps
import cpu_pkg::*;

module top #(
  parameter int    PHYS_REGS   = 128,
  parameter int    ROB_ENTRIES = 16,
  parameter int    WORDS       = 512,
  parameter int    DMEM_WORDS  = 32768,
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
  fetch_dual_pkt_t fetch_pkt;
  logic            valid_fetch;
  logic            ready_out_fetch;

  fetch_module #(
    .WORDS   (WORDS),
    .MEMFILE (MEMFILE)
  ) u_fetch (
    .clk            (clk),
    .reset          (reset),
    .pc_src         (branch_mispredict),
    .pc_branch      (branch_target),
    .pred_taken_0_i (bp_pred_taken_fetch),
    .pred_target_0_i(bp_pred_target_fetch),
    .pred_taken_1_i (1'b0),  // TODO: connect to dual BP
    .pred_target_1_i(32'h0),
    .ready_out      (ready_out_fetch),
    .valid_in       (valid_fetch),
    .fetch_pkt      (fetch_pkt)
  );

  assign pc_out = fetch_pkt.pc0;  // For observation

  branch_predictor #(
    .ENTRIES(8)
  ) u_bp (
    .clk            (clk),
    .reset          (reset),
    .fetch_pc_i     (fetch_pkt.pc0),
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
  logic            valid_fetch_to_decode;
  logic            ready_decode_to_fetch;
  fetch_dual_pkt_t fetch_pkt_decode;

  pipeline_skid_buffer_struct #(
    .T(fetch_dual_pkt_t)
  ) u_skid_fetch_decode (
    .clk       (clk),
    .reset     (reset),
    .flush     (branch_mispredict),
    .valid_in  (valid_fetch),
    .ready_in  (ready_out_fetch),
    .data_in   (fetch_pkt),
    .valid_out (valid_fetch_to_decode),
    .ready_out (ready_decode_to_fetch),
    .data_out  (fetch_pkt_decode)
  );

  // ============================================================
  // STAGE 2: DECODE
  // ============================================================
  decode_dual_pkt_t decode_pkt_decode;

  decode_module u_decode (
    .clk        (clk),
    .reset      (reset),
    .fetch_pkt  (fetch_pkt_decode),
    .decode_pkt (decode_pkt_decode)
  );

  // ============================================================
  // Skid Buffer: Decode -> Rename
  // ============================================================
  logic             valid_decode_to_rename;
  logic             ready_rename_to_decode;
  decode_dual_pkt_t decode_pkt_rename;

  pipeline_skid_buffer_struct #(
    .T(decode_dual_pkt_t)
  ) u_skid_decode_rename (
    .clk       (clk),
    .reset     (reset),
    .flush     (branch_mispredict),
    .valid_in  (valid_fetch_to_decode),
    .ready_in  (ready_decode_to_fetch),
    .data_in   (decode_pkt_decode),
    .valid_out (valid_decode_to_rename),
    .ready_out (ready_rename_to_decode),
    .data_out  (decode_pkt_rename)
  );

  // ============================================================
  // STAGE 3: RENAME
  // ============================================================
  logic             valid_rename_to_dispatch;
  logic             ready_dispatch_to_rename;
  rename_dual_pkt_t rename_pkt;

  // Dual commit signals from ROB (for retire)
  logic        commit_valid_0, commit_valid_1;
  logic        commit_writes_rd_0, commit_writes_rd_1;
  logic [6:0]  commit_dst_old_0, commit_dst_old_1;
  logic [ROB_BITS-1:0] commit_rob_tag_0, commit_rob_tag_1;

  rename_module #(
    .ARCH_REGS   (32),
    .PHYS_REGS   (PHYS_REGS),
    .ROB_ENTRIES (ROB_ENTRIES)
  ) u_rename (
    .clk                    (clk),
    .reset                  (reset),
    // Dual-issue input from decode skid buffer
    .ready_from_dispatch    (ready_dispatch_to_rename),
    .decode_pkt_i           (decode_pkt_rename),
    .valid_from_decode      (valid_decode_to_rename),
    // Branch misprediction recovery
    .branch_miss_rename     (branch_mispredict),
    .recover_tag_i          (mispredict_rob_tag),
    // Dual retire signals from ROB dual commit
    .retire_enable_0        (commit_valid_0 && commit_writes_rd_0),
    .retired_destReg_phys_0 (commit_dst_old_0),
    .retire_enable_1        (commit_valid_1 && commit_writes_rd_1),
    .retired_destReg_phys_1 (commit_dst_old_1),
    // Dual-issue output to dispatch
    .valid_to_dispatch      (valid_rename_to_dispatch),
    .ready_to_decode        (ready_rename_to_decode),
    .rename_pkt_o           (rename_pkt)
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

  // Second ALU issue signals (ALU1)
  logic        alu1_issue_valid;
  rs_pkt_t     alu1_issue_pkt;
  logic [31:0] alu1_src0_data, alu1_src1_data;

  // Writeback signals from execution units
  logic        wb_alu_valid, wb_br_valid, wb_lsu_valid;
  logic [6:0]  wb_alu_prf, wb_br_prf, wb_lsu_prf;
  logic [31:0] wb_alu_data, wb_br_data, wb_lsu_data;
  logic [ROB_BITS-1:0] wb_alu_rob_tag, wb_br_rob_tag, wb_lsu_rob_tag;

  // Second ALU writeback signals (ALU1)
  logic        wb_alu1_valid;
  logic [6:0]  wb_alu1_prf;
  logic [31:0] wb_alu1_data;
  logic [ROB_BITS-1:0] wb_alu1_rob_tag;

  // EXU ready signals - forward declarations (assigned after execution units)
  logic alu_ready, br_ready, lsu_ready, alu1_ready;

  // Branch completion signals (separate from writeback - BNE completes but doesn't write)
  logic        complete_br_valid;
  logic [ROB_BITS-1:0] complete_br_rob_tag;

  // LSQ signals
  logic [ROB_BITS-1:0] rob_head_dispatch, rob_tail_cp_dispatch;
  logic [ROB_BITS-1:0] commit_rob_tag;
  logic store_alloc_valid;
  logic [ROB_BITS-1:0] store_alloc_rob_tag;
  
  dispatch_module #(
    .PHYS_REGS(PHYS_REGS),
    .ROB_DEPTH(ROB_ENTRIES)
  ) u_dispatch (
    .clk              (clk),
    .reset            (reset),
    .recover_i        (branch_mispredict),
    // From rename (dual-issue packet)
    .rn_valid_i       (valid_rename_to_dispatch),
    .rn_ready_o       (ready_dispatch_to_rename),
    .rn_pkt_i         (rename_pkt),
    // EXU ready
    .alu_exu_ready_i  (alu_ready),
    .alu1_exu_ready_i (alu1_ready),
    .br_exu_ready_i   (br_ready),
    .lsu_exu_ready_i  (lsu_ready),
    // Issue outputs - ALU0
    .alu_issue_valid_o(alu_issue_valid),
    .alu_issue_pkt_o  (alu_issue_pkt),
    .alu_src0_data_o  (alu_src0_data),
    .alu_src1_data_o  (alu_src1_data),
    // Issue outputs - ALU1
    .alu1_issue_valid_o(alu1_issue_valid),
    .alu1_issue_pkt_o  (alu1_issue_pkt),
    .alu1_src0_data_o  (alu1_src0_data),
    .alu1_src1_data_o  (alu1_src1_data),
    // Issue outputs - Branch
    .br_issue_valid_o (br_issue_valid),
    .br_issue_pkt_o   (br_issue_pkt),
    .br_src0_data_o   (br_src0_data),
    .br_src1_data_o   (br_src1_data),
    // Issue outputs - LSU
    .lsu_issue_valid_o(lsu_issue_valid),
    .lsu_issue_pkt_o  (lsu_issue_pkt),
    .lsu_src0_data_o  (lsu_src0_data),
    .lsu_src1_data_o  (lsu_src1_data),
    // Writeback inputs - ALU0
    .wb_alu_valid_i   (wb_alu_valid),
    .wb_alu_prf_i     (wb_alu_prf),
    .wb_alu_data_i    (wb_alu_data),
    .wb_alu_rob_tag_i (wb_alu_rob_tag),
    // Writeback inputs - ALU1
    .wb_alu1_valid_i  (wb_alu1_valid),
    .wb_alu1_prf_i    (wb_alu1_prf),
    .wb_alu1_data_i   (wb_alu1_data),
    .wb_alu1_rob_tag_i(wb_alu1_rob_tag),
    // Writeback inputs - Branch
    .wb_br_valid_i    (wb_br_valid),
    .wb_br_prf_i      (wb_br_prf),
    .wb_br_data_i     (wb_br_data),
    .wb_br_rob_tag_i  (wb_br_rob_tag),
    // Writeback inputs - LSU
    .wb_lsu_valid_i   (wb_lsu_valid),
    .wb_lsu_prf_i     (wb_lsu_prf),
    .wb_lsu_data_i    (wb_lsu_data),
    .wb_lsu_rob_tag_i (wb_lsu_rob_tag),
    // Branch completion (separate from writeback - BNE completes but doesn't write)
    .complete_br_valid_i   (complete_br_valid),
    .complete_br_rob_tag_i (complete_br_rob_tag),
    // Dual commit outputs
    .commit_valid_0_o     (commit_valid_0),
    .commit_writes_rd_0_o (commit_writes_rd_0),
    .commit_dst_old_0_o   (commit_dst_old_0),
    .commit_rob_tag_0_o   (commit_rob_tag_0),
    .commit_valid_1_o     (commit_valid_1),
    .commit_writes_rd_1_o (commit_writes_rd_1),
    .commit_dst_old_1_o   (commit_dst_old_1),
    .commit_rob_tag_1_o   (commit_rob_tag_1),
    // ROB head/tail for LSQ
    .rob_head_o       (rob_head_dispatch),
    .rob_tail_cp_o    (rob_tail_cp_dispatch),
    // Store allocation for LSQ
    .store_alloc_valid_o   (store_alloc_valid),
    .store_alloc_rob_tag_o (store_alloc_rob_tag),
    // LSQ ready for store backpressure
    .lsq_alloc_ready_i     (sq_alloc_ready)
  );

  // ============================================================
  // EXECUTION UNITS
  // ============================================================
  
  // ----- ALU Unit 0 -----
  ALU_unit u_alu0 (
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

  // ----- ALU Unit 1 (Second ALU for dual-issue) -----
  ALU_unit u_alu1 (
    .clk          (clk),
    .reset        (reset),
    .flush_i      (branch_mispredict),
    .valid_i      (alu1_issue_valid),
    .pkt_i        (alu1_issue_pkt),
    .src0_data_i  (alu1_src0_data),
    .src1_data_i  (alu1_src1_data),
    .ready_o      (alu1_ready),
    .wb_valid_o   (wb_alu1_valid),
    .wb_data_o    (wb_alu1_data),
    .wb_dst_prf_o (wb_alu1_prf),
    .wb_rob_tag_o (wb_alu1_rob_tag)
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

  // ----- LSU Unit with LSQ -----
  logic [31:0] dmem_addr, dmem_rdata;
  logic        dmem_re;
  
  // LSQ Store signals
  logic        lsq_store_valid;
  logic [31:0] lsq_store_addr, lsq_store_data;
  logic [3:0]  lsq_store_be;
  logic [ROB_BITS-1:0] lsq_store_rob_tag;
  
  // LSQ Load forward signals
  logic        lsq_load_fwd_req;
  logic [ROB_BITS-1:0] lsq_load_fwd_rob_tag;
  logic [31:0] lsq_load_fwd_addr;
  logic        lsq_load_fwd_valid;
  logic [31:0] lsq_load_fwd_data;
  logic [3:0]  lsq_load_fwd_be;
  
  // LSQ allocation signals
  logic        sq_alloc_ready;
  logic [2:0]  sq_alloc_idx;
  
  // LSQ dual commit signals
  logic        sq_commit_ready_0, sq_commit_ready_1;
  logic        mem_write_valid_0, mem_write_valid_1;
  logic [31:0] mem_write_addr_0, mem_write_data_0;
  logic [31:0] mem_write_addr_1, mem_write_data_1;
  logic [3:0]  mem_write_be_0, mem_write_be_1;

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
    // LSQ Store Write Interface
    .lsq_store_valid_o    (lsq_store_valid),
    .lsq_store_addr_o     (lsq_store_addr),
    .lsq_store_data_o     (lsq_store_data),
    .lsq_store_be_o       (lsq_store_be),
    .lsq_store_rob_tag_o  (lsq_store_rob_tag),
    // LSQ Load Forward Interface
    .lsq_load_fwd_req_o       (lsq_load_fwd_req),
    .lsq_load_fwd_rob_tag_o   (lsq_load_fwd_rob_tag),
    .lsq_load_fwd_addr_o      (lsq_load_fwd_addr),
    .lsq_load_fwd_valid_i     (lsq_load_fwd_valid),
    .lsq_load_fwd_data_i      (lsq_load_fwd_data),
    .lsq_load_fwd_be_i        (lsq_load_fwd_be),
    // Memory Interface (loads only)
    .dmem_addr_o  (dmem_addr),
    .dmem_re_o    (dmem_re),
    .dmem_rdata_i (dmem_rdata)
  );

  // ============================================================
  // LOAD-STORE QUEUE
  // ============================================================
  LSQ #(
    .SQ_DEPTH    (8),
    .ROB_ENTRIES (ROB_ENTRIES)
  ) u_lsq (
    .clk          (clk),
    .reset        (reset),
    .flush_i      (branch_mispredict),
    // ROB interface
    .rob_head_i   (rob_head_dispatch),
    .rob_tail_cp_i(rob_tail_cp_dispatch),
    // Store allocation (when store dispatches)
    .sq_alloc_valid_i   (store_alloc_valid),
    .sq_alloc_rob_tag_i (store_alloc_rob_tag),
    .sq_alloc_ready_o   (sq_alloc_ready),
    .sq_alloc_idx_o     (sq_alloc_idx),
    // Store address/data write (when store issues)
    .sq_write_valid_i   (lsq_store_valid),
    .sq_write_rob_tag_i (lsq_store_rob_tag),
    .sq_write_addr_i    (lsq_store_addr),
    .sq_write_data_i    (lsq_store_data),
    .sq_write_be_i      (lsq_store_be),
    // Load forward request
    .ld_fwd_req_i       (lsq_load_fwd_req),
    .ld_fwd_rob_tag_i   (lsq_load_fwd_rob_tag),
    .ld_fwd_addr_i      (lsq_load_fwd_addr),
    .ld_fwd_valid_o     (lsq_load_fwd_valid),
    .ld_fwd_data_o      (lsq_load_fwd_data),
    .ld_fwd_be_o        (lsq_load_fwd_be),
    // Dual store commit (from ROB)
    // Send all commits to LSQ; LSQ will check if ROB tag matches a store
    .sq_commit_valid_0_i   (commit_valid_0),
    .sq_commit_rob_tag_0_i (commit_rob_tag_0),
    .sq_commit_ready_0_o   (sq_commit_ready_0),
    .sq_commit_valid_1_i   (commit_valid_1),
    .sq_commit_rob_tag_1_i (commit_rob_tag_1),
    .sq_commit_ready_1_o   (sq_commit_ready_1),
    // Dual memory write interface
    .mem_write_valid_0_o  (mem_write_valid_0),
    .mem_write_addr_0_o   (mem_write_addr_0),
    .mem_write_data_0_o   (mem_write_data_0),
    .mem_write_be_0_o     (mem_write_be_0),
    .mem_write_valid_1_o  (mem_write_valid_1),
    .mem_write_addr_1_o   (mem_write_addr_1),
    .mem_write_data_1_o   (mem_write_data_1),
    .mem_write_be_1_o     (mem_write_be_1)
  );

  // ============================================================
  // DATA MEMORY
  // ============================================================
  // Arbitration logic for dual store commits (prioritize store_0)
  // Note: True dual-write would require dual-port BRAM, but since stores commit in-order,
  // we can safely prioritize store_0. In practice, most cycles have at most 1 store committing.
  logic        dmem_we_arb;
  logic [31:0] dmem_waddr_arb, dmem_wdata_arb;
  logic [3:0]  dmem_wbe_arb;

  always_comb begin
    if (mem_write_valid_0) begin
      dmem_we_arb    = 1'b1;
      dmem_waddr_arb = mem_write_addr_0;
      dmem_wdata_arb = mem_write_data_0;
      dmem_wbe_arb   = mem_write_be_0;
    end else if (mem_write_valid_1) begin
      dmem_we_arb    = 1'b1;
      dmem_waddr_arb = mem_write_addr_1;
      dmem_wdata_arb = mem_write_data_1;
      dmem_wbe_arb   = mem_write_be_1;
    end else begin
      dmem_we_arb    = 1'b0;
      dmem_waddr_arb = '0;
      dmem_wdata_arb = '0;
      dmem_wbe_arb   = 4'b0000;
    end
  end

  data_memory #(
    .WORDS(DMEM_WORDS) // default: 131072 words = 512KB (32-bit words)
  ) u_dmem (
    .clk   (clk),
    // Read port (loads)
    .re    (dmem_re),
    .raddr (dmem_addr),
    // Write port (committed stores, arbitrated)
    .we    (dmem_we_arb ? dmem_wbe_arb : 4'b0000),
    .waddr (dmem_waddr_arb),
    .wdata (dmem_wdata_arb),
    .rdata (dmem_rdata)
  );

  // ============================================================
  // Output Assignments
  // ============================================================
  // pc_out is already assigned near fetch_module (line 66)
  assign commit_valid_o = commit_valid_0 || commit_valid_1;

endmodule