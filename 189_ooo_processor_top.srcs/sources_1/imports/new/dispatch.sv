`timescale 1ns/1ps

import cpu_pkg::*;

// Dispatch top-level
// - Receives rename stage inputs and applies back-pressure via a single-entry pipeline buffer
// - Allocates into the 16-entry ROB and the selected 8-entry RS
// - Uses the PRF busy scoreboard to determine operand readiness and marks destinations busy on allocation
// - Connects three issue paths to the PRF read ports and forwards operands plus packets to the execution units
module dispatch_module #(
    parameter int PHYS_REGS = 128,
    parameter int ROB_DEPTH = 16       
) (
    input  logic clk,
    input  logic reset,
    input  logic recover_i,

    // Inputs from rename (valid/ready handshake)
    input  logic            rn_valid_i,
    output logic            rn_ready_o,
    input  logic [6:0]      rn_micro_op_i,
    input  logic [PRF_BITS-1:0] rn_dst_prf_new_i,
    input  logic [PRF_BITS-1:0] rn_dst_prf_old_i,
    input  logic [PRF_BITS-1:0] rn_src0_prf_i,
    input  logic [PRF_BITS-1:0] rn_src1_prf_i,
    input  logic [IMM_BITS-1:0] rn_imm_i,
    input  logic [1:0]      rn_fu_i,          // 0-ALU,1-BR,2-LSU
    input  logic            rn_is_branch_i,
    input  logic            rn_writes_rd_i,
    input  logic [$clog2(ROB_DEPTH)-1:0] rn_rob_tag_i,
    input  logic [31:0]     rn_pc_i,          // instruction PC (for branch target calc)
    input  logic            rn_pred_hit_i,
    input  logic            rn_pred_taken_i,
    input  logic [31:0]     rn_pred_target_i,

    // Ready signals from the downstream execution units (each RS issues at most one instruction when the EXU is ready)
    input  logic alu_exu_ready_i,
    input  logic br_exu_ready_i,
    input  logic lsu_exu_ready_i,

    // Outputs toward the EXUs: at most one per class per cycle
    output logic   alu_issue_valid_o,
    output rs_pkt_t alu_issue_pkt_o,
    output logic [31:0] alu_src0_data_o,
    output logic [31:0] alu_src1_data_o,

    output logic   br_issue_valid_o,
    output rs_pkt_t br_issue_pkt_o,
    output logic [31:0] br_src0_data_o,
    output logic [31:0] br_src1_data_o,

    output logic   lsu_issue_valid_o,
    output rs_pkt_t lsu_issue_pkt_o,
    output logic [31:0] lsu_src0_data_o,
    output logic [31:0] lsu_src1_data_o,

    // Writeback inputs from execution units (for PRF update and wakeup)
    input  logic        wb_alu_valid_i,
    input  logic [6:0]  wb_alu_prf_i,
    input  logic [31:0] wb_alu_data_i,

    input  logic        wb_br_valid_i,
    input  logic [6:0]  wb_br_prf_i,
    input  logic [31:0] wb_br_data_i,

    input  logic        wb_lsu_valid_i,
    input  logic [6:0]  wb_lsu_prf_i,
    input  logic [31:0] wb_lsu_data_i,

    // ROB tag from writeback (for marking complete)
    input  logic [$clog2(ROB_DEPTH)-1:0] wb_alu_rob_tag_i,
    input  logic [$clog2(ROB_DEPTH)-1:0] wb_br_rob_tag_i,
    input  logic [$clog2(ROB_DEPTH)-1:0] wb_lsu_rob_tag_i,
    
    // Branch completion (separate from writeback - BNE completes but doesn't write)
    input  logic        complete_br_valid_i,
    input  logic [$clog2(ROB_DEPTH)-1:0] complete_br_rob_tag_i,

    // Commit outputs (broadcast to rename - NO ready signal, must always accept!)
    output logic        commit_valid_o,
    output logic        commit_writes_rd_o,
    output logic [6:0]  commit_dst_old_o,
    output logic [$clog2(ROB_DEPTH)-1:0] commit_rob_tag_o,
    
    // ROB head/tail for LSQ age comparison
    output logic [$clog2(ROB_DEPTH)-1:0] rob_head_o,
    output logic [$clog2(ROB_DEPTH)-1:0] rob_tail_cp_o,
    
    // Store allocation for LSQ (when store dispatches)
    output logic        store_alloc_valid_o,
    output logic [$clog2(ROB_DEPTH)-1:0] store_alloc_rob_tag_o,
    
    // LSQ ready signal (for store dispatch backpressure)
    input  logic        lsq_alloc_ready_i
);
    // Same-cycle forwarding for issued operands.
    // Priority (to preserve old PRF behavior if multiple WB hit same preg):
    //   ALU > BR > LSU > PRF
    function automatic logic [31:0] op_with_bypass(
        input logic [PRF_BITS-1:0] addr,
        input logic [31:0]          prf_data
    );
        logic addr_nz;
        logic hit_alu, hit_br, hit_lsu;
        logic oh_alu, oh_br, oh_lsu, oh_prf;
        logic [31:0] data;
        begin
            addr_nz = (addr != '0);

            hit_alu = wb_alu_valid_i && addr_nz && (wb_alu_prf_i == addr);
            hit_br  = wb_br_valid_i  && addr_nz && (wb_br_prf_i  == addr);
            hit_lsu = wb_lsu_valid_i && addr_nz && (wb_lsu_prf_i == addr);

            oh_alu = hit_alu;
            oh_br  = hit_br  && !hit_alu;
            oh_lsu = hit_lsu && !hit_alu && !hit_br;
            oh_prf = !(oh_alu || oh_br || oh_lsu);

            data = ({32{oh_alu}} & wb_alu_data_i)
                 | ({32{oh_br}}  & wb_br_data_i)
                 | ({32{oh_lsu}} & wb_lsu_data_i)
                 | ({32{oh_prf}} & prf_data);

            op_with_bypass = data;
        end
    endfunction

    // ==================================
    // 1. Single-entry pipeline buffer
    // ==================================
    rename_pkt_t rn_pkt_in;
    assign rn_pkt_in.micro_op     = rn_micro_op_i;
    assign rn_pkt_in.dst_prf_new  = rn_dst_prf_new_i;
    assign rn_pkt_in.dst_prf_old  = rn_dst_prf_old_i;
    assign rn_pkt_in.src0_prf     = rn_src0_prf_i;
    assign rn_pkt_in.src1_prf     = rn_src1_prf_i;
    assign rn_pkt_in.imm          = rn_imm_i;
    assign rn_pkt_in.fu           = rn_fu_i;
    assign rn_pkt_in.is_branch    = rn_is_branch_i;
    assign rn_pkt_in.writes_rd    = rn_writes_rd_i;
    assign rn_pkt_in.rob_tag      = rn_rob_tag_i;
    assign rn_pkt_in.pc           = rn_pc_i;
    assign rn_pkt_in.pred_hit     = rn_pred_hit_i;
    assign rn_pkt_in.pred_taken   = rn_pred_taken_i;
    assign rn_pkt_in.pred_target  = rn_pred_target_i;

    logic        pb_valid;
    rename_pkt_t pb_pkt;
    logic        pb_ready;  

    pipeline_skid_buffer_struct #(
        .T(rename_pkt_t)
    ) u_skid_rn_dispatch (
        .clk       (clk),
        .reset     (reset),
        .flush     (recover_i),
        .valid_in  (rn_valid_i),
        .ready_in  (rn_ready_o),
        .data_in   (rn_pkt_in),
        .valid_out (pb_valid),
        .ready_out (pb_ready),
        .data_out  (pb_pkt)
    );

    // =====================
    // 2. PRF with busy scoreboard
    // =====================
    logic [PHYS_REGS-1:0] prf_busy_bits;

    // Raw PRF read data (no bypass inside PRF)
    logic [31:0] alu_src0_data_raw, alu_src1_data_raw;
    logic [31:0] br_src0_data_raw,  br_src1_data_raw;
    logic [31:0] lsu_src0_data_raw, lsu_src1_data_raw;

    // Writeback and explicit busy-clear paths are not hooked up yet; only set busy on allocation
    logic        prf_set_busy_en;
    logic [6:0]  prf_set_busy_preg;

    PRF #(
        .PHYS_REGS(PHYS_REGS)
    ) u_prf (
        .clk              (clk),
        .reset            (reset),
        // Writeback ports from EXUs (update PRF data and clear busy)
        .wb_alu_en_i      (wb_alu_valid_i),
        .wb_alu_preg_i    (wb_alu_prf_i),
        .wb_alu_data_i    (wb_alu_data_i),

        .wb_br_en_i       (wb_br_valid_i),
        .wb_br_preg_i     (wb_br_prf_i),
        .wb_br_data_i     (wb_br_data_i),

        .wb_lsu_en_i      (wb_lsu_valid_i),
        .wb_lsu_preg_i    (wb_lsu_prf_i),
        .wb_lsu_data_i    (wb_lsu_data_i),

        // Busy scoreboard control
        .set_busy_en_i    (prf_set_busy_en),
        .set_busy_preg_i  (prf_set_busy_preg),
        .clr_busy_en_i    (1'b0),
        .clr_busy_preg_i  ('0),
        .busy_o           (prf_busy_bits),
        // Three issue read ports
        .iss0_valid_i     (alu_issue_valid_o),
        .iss0_src0_i      (alu_issue_pkt_o.src0_prf),
        .iss0_src1_i      (alu_issue_pkt_o.src1_prf),
        .iss0_r0_o        (alu_src0_data_raw),
        .iss0_r1_o        (alu_src1_data_raw),

        .iss1_valid_i     (br_issue_valid_o),
        .iss1_src0_i      (br_issue_pkt_o.src0_prf),
        .iss1_src1_i      (br_issue_pkt_o.src1_prf),
        .iss1_r0_o        (br_src0_data_raw),
        .iss1_r1_o        (br_src1_data_raw),

        .iss2_valid_i     (lsu_issue_valid_o),
        .iss2_src0_i      (lsu_issue_pkt_o.src0_prf),
        .iss2_src1_i      (lsu_issue_pkt_o.src1_prf),
        .iss2_r0_o        (lsu_src0_data_raw),
        .iss2_r1_o        (lsu_src1_data_raw)
    );

    // Apply same-cycle operand bypass here (moved out of PRF)
    assign alu_src0_data_o = op_with_bypass(alu_issue_pkt_o.src0_prf, alu_src0_data_raw);
    assign alu_src1_data_o = op_with_bypass(alu_issue_pkt_o.src1_prf, alu_src1_data_raw);
    assign br_src0_data_o  = op_with_bypass(br_issue_pkt_o.src0_prf,  br_src0_data_raw);
    assign br_src1_data_o  = op_with_bypass(br_issue_pkt_o.src1_prf,  br_src1_data_raw);
    assign lsu_src0_data_o = op_with_bypass(lsu_issue_pkt_o.src0_prf, lsu_src0_data_raw);
    assign lsu_src1_data_o = op_with_bypass(lsu_issue_pkt_o.src1_prf, lsu_src1_data_raw);

    // =====================
    // 3. Three reservation stations (each with 8 entries)
    // =====================
    // Forward declare ROB outputs needed by RS
    logic [$clog2(ROB_DEPTH)-1:0] rob_head_out;
    logic [$clog2(ROB_DEPTH)-1:0] rob_tail_cp_out;
    
    // ALU RS - Uses "oldest among ready" policy
    logic        alu_alloc_ready;
    logic        alu_alloc_valid;
    rs_pkt_t     alu_alloc_pkt;
    RS #(
        .PHYS_REGS  (PHYS_REGS),
        .ROB_ENTRIES(ROB_DEPTH)
    ) u_rs_alu (
        .clk                  (clk),
        .reset                (reset),
        .recover_i            (recover_i),
        .rob_head_i           (rob_head_out),
        .rob_tail_cp_i        (rob_tail_cp_out),
        .prf_busy_i           (prf_busy_bits),
        .wb_alu_valid_i       (wb_alu_valid_i),
        .wb_alu_prf_i         (wb_alu_prf_i),
        .wb_br_valid_i        (wb_br_valid_i),
        .wb_br_prf_i          (wb_br_prf_i),
        .wb_lsu_valid_i       (wb_lsu_valid_i),
        .wb_lsu_prf_i         (wb_lsu_prf_i),
        .alloc_valid_i        (alu_alloc_valid),
        .alloc_ready_o        (alu_alloc_ready),
        .alloc_pkt_i          (alu_alloc_pkt),
        .exu_ready_i          (alu_exu_ready_i),
        .issue_valid_o        (alu_issue_valid_o),
        .issue_pkt_o          (alu_issue_pkt_o)
    );

    // BR RS - Uses "oldest among ready" policy
    logic        br_alloc_ready;
    logic        br_alloc_valid;
    rs_pkt_t     br_alloc_pkt;
    RS #(
        .PHYS_REGS  (PHYS_REGS),
        .ROB_ENTRIES(ROB_DEPTH)
    ) u_rs_br (
        .clk                  (clk),
        .reset                (reset),
        .recover_i            (recover_i),
        .rob_head_i           (rob_head_out),
        .rob_tail_cp_i        (rob_tail_cp_out),
        .prf_busy_i           (prf_busy_bits),
        .wb_alu_valid_i       (wb_alu_valid_i),
        .wb_alu_prf_i         (wb_alu_prf_i),
        .wb_br_valid_i        (wb_br_valid_i),
        .wb_br_prf_i          (wb_br_prf_i),
        .wb_lsu_valid_i       (wb_lsu_valid_i),
        .wb_lsu_prf_i         (wb_lsu_prf_i),
        .alloc_valid_i        (br_alloc_valid),
        .alloc_ready_o        (br_alloc_ready),
        .alloc_pkt_i          (br_alloc_pkt),
        .exu_ready_i          (br_exu_ready_i),
        .issue_valid_o        (br_issue_valid_o),
        .issue_pkt_o          (br_issue_pkt_o)
    );

    // LSU RS - Uses "oldest among ready" policy (LSQ handles memory ordering)
    logic        lsu_alloc_ready;
    logic        lsu_alloc_valid;
    rs_pkt_t     lsu_alloc_pkt;
    RS #(
        .PHYS_REGS  (PHYS_REGS),
        .ROB_ENTRIES(ROB_DEPTH)
    ) u_rs_lsu (
        .clk                  (clk),
        .reset                (reset),
        .recover_i            (recover_i),
        .rob_head_i           (rob_head_out),
        .rob_tail_cp_i        (rob_tail_cp_out),
        .prf_busy_i           (prf_busy_bits),
        .wb_alu_valid_i       (wb_alu_valid_i),
        .wb_alu_prf_i         (wb_alu_prf_i),
        .wb_br_valid_i        (wb_br_valid_i),
        .wb_br_prf_i          (wb_br_prf_i),
        .wb_lsu_valid_i       (wb_lsu_valid_i),
        .wb_lsu_prf_i         (wb_lsu_prf_i),
        .alloc_valid_i        (lsu_alloc_valid),
        .alloc_ready_o        (lsu_alloc_ready),
        .alloc_pkt_i          (lsu_alloc_pkt),
        .exu_ready_i          (lsu_exu_ready_i),
        .issue_valid_o        (lsu_issue_valid_o),
        .issue_pkt_o          (lsu_issue_pkt_o)
    );

    // =====================
    // 4. ROB (16-entry circular buffer)
    // =====================
    logic                       rob_ready;
    logic [$clog2(ROB_DEPTH)-1:0] rob_tail_idx;
    
    // Declare accept before use in ROB
    logic accept;
    assign accept = pb_valid & pb_ready;

    ROB #(.ROB_ENTRIES(ROB_DEPTH)) u_rob (
        .clk                  (clk),
        .reset                (reset),
        .recover_i            (recover_i),
        .mispredict_rob_tag_i (wb_br_rob_tag_i),  // ROB tag of mispredicting branch
        // Allocation
        .valid_i              (accept),
        .ready_o              (rob_ready),
        .is_branch_i          (pb_pkt.is_branch),
        .writes_rd_i          (pb_pkt.writes_rd),
        .dst_new_i            (pb_pkt.dst_prf_new),
        .dst_old_i            (pb_pkt.dst_prf_old),
        .rob_tag_i            (pb_pkt.rob_tag),
        .tag_o                (rob_tail_idx),
        .full_o               (),
        .head_o               (rob_head_out),
        .tail_cp_o            (rob_tail_cp_out),
        // Complete signals from EXUs
        .complete_alu_valid_i (wb_alu_valid_i),
        .complete_alu_tag_i   (wb_alu_rob_tag_i),
        .complete_br_valid_i  (complete_br_valid_i),   // Use dedicated completion signal
        .complete_br_tag_i    (complete_br_rob_tag_i), // Use dedicated completion tag
        .complete_lsu_valid_i (wb_lsu_valid_i),
        .complete_lsu_tag_i   (wb_lsu_rob_tag_i),
        // Commit outputs
        .commit_valid_o       (commit_valid_o),
        .commit_writes_rd_o   (commit_writes_rd_o),
        .commit_dst_old_o     (commit_dst_old_o)
    );

    // =====================
    // 5. Allocation control and packet assembly （combinational）
    // =====================
    // Determine whether the target RS (based on FU type) has an available slot
    logic target_rs_ready;
    logic is_store_instr;
    
    // micro_op[1] = sw (store operation)
    assign is_store_instr = (pb_pkt.fu == 2'd2) && pb_pkt.micro_op[1];
    
    always_comb begin
        unique case (pb_pkt.fu)
            2'd0: target_rs_ready = alu_alloc_ready;
            2'd1: target_rs_ready = br_alloc_ready;
            2'd2: target_rs_ready = lsu_alloc_ready;
            default: target_rs_ready = 1'b0;
        endcase
    end

    // Skid consumer is ready only if:
    // 1. ROB can accept
    // 2. Target RS has room
    // 3. For store: LSQ has room
    assign pb_ready = rob_ready & target_rs_ready & (!is_store_instr | lsq_alloc_ready_i);

    // Only on accept do we assert alloc_valid for the chosen RS and build the rs_pkt
    // Also mark the destination PRF busy when the instruction writes back
    always_comb begin
        // Default assignments
        alu_alloc_valid = 1'b0; br_alloc_valid = 1'b0; lsu_alloc_valid = 1'b0;
        alu_alloc_pkt   = '0;   br_alloc_pkt   = '0;   lsu_alloc_pkt   = '0;
        prf_set_busy_en    = 1'b0;
        prf_set_busy_preg  = '0;

        if (accept) begin
            // Build a common rs_pkt_t structure
            rs_pkt_t pkt;
            pkt.valid      = 1'b1;
            pkt.micro_op   = pb_pkt.micro_op;
            pkt.dst_prf    = pb_pkt.dst_prf_new;
            pkt.src0_prf   = pb_pkt.src0_prf;
            pkt.src0_ready = 1'b0; // RS recomputes readiness from the busy scoreboard
            pkt.src1_prf   = pb_pkt.src1_prf;
            pkt.src1_ready = 1'b0;
            pkt.imm        = pb_pkt.imm;
            pkt.fu         = pb_pkt.fu;
            pkt.rob_tag    = rob_tail_idx;
            pkt.pc         = pb_pkt.pc;
            pkt.pred_hit    = pb_pkt.pred_hit;
            pkt.pred_taken  = pb_pkt.pred_taken;
            pkt.pred_target = pb_pkt.pred_target;

            unique case (pb_pkt.fu)
                2'd0: begin
                    alu_alloc_valid = 1'b1;
                    alu_alloc_pkt   = pkt;
                end
                2'd1: begin
                    br_alloc_valid  = 1'b1;
                    br_alloc_pkt    = pkt;
                end
                2'd2: begin
                    lsu_alloc_valid = 1'b1;
                    lsu_alloc_pkt   = pkt;
                end
                default: begin
                    // No RS selected
                end
            endcase

            if (pb_pkt.writes_rd && (pb_pkt.dst_prf_new != '0)) begin
                prf_set_busy_en   = 1'b1;
                prf_set_busy_preg = pb_pkt.dst_prf_new[6:0];
            end
        end
    end

    // ROB head/tail outputs for LSQ
    assign rob_head_o    = rob_head_out;
    assign rob_tail_cp_o = rob_tail_cp_out;
    
    // Store allocation: when a store dispatches to LSU RS
    // micro_op[1] = sw (store operation)
    assign store_alloc_valid_o   = lsu_alloc_valid && lsu_alloc_pkt.micro_op[1];
    assign store_alloc_rob_tag_o = rob_tail_idx;
    
    // Commit ROB tag output (commit always happens at head)
    assign commit_rob_tag_o = rob_head_out;

endmodule
