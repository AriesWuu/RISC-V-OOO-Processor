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

    // Dual-issue inputs from rename (valid/ready handshake)
    input  logic            rn_valid_i,
    output logic            rn_ready_o,
    input  rename_dual_pkt_t rn_pkt_i,

    // Ready signals from the downstream execution units (each RS issues at most one instruction when the EXU is ready)
    input  logic alu_exu_ready_i,
    input  logic alu1_exu_ready_i,      // Second ALU ready signal
    input  logic br_exu_ready_i,
    input  logic lsu_exu_ready_i,

    // Outputs toward the EXUs: at most one per class per cycle
    output logic   alu_issue_valid_o,
    output rs_pkt_t alu_issue_pkt_o,
    output logic [31:0] alu_src0_data_o,
    output logic [31:0] alu_src1_data_o,

    // Second ALU outputs
    output logic   alu1_issue_valid_o,
    output rs_pkt_t alu1_issue_pkt_o,
    output logic [31:0] alu1_src0_data_o,
    output logic [31:0] alu1_src1_data_o,

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

    // Second ALU writeback inputs
    input  logic        wb_alu1_valid_i,
    input  logic [6:0]  wb_alu1_prf_i,
    input  logic [31:0] wb_alu1_data_i,

    input  logic        wb_br_valid_i,
    input  logic [6:0]  wb_br_prf_i,
    input  logic [31:0] wb_br_data_i,

    input  logic        wb_lsu_valid_i,
    input  logic [6:0]  wb_lsu_prf_i,
    input  logic [31:0] wb_lsu_data_i,

    // ROB tag from writeback (for marking complete)
    input  logic [$clog2(ROB_DEPTH)-1:0] wb_alu_rob_tag_i,
    input  logic [$clog2(ROB_DEPTH)-1:0] wb_alu1_rob_tag_i,    // Second ALU ROB tag
    input  logic [$clog2(ROB_DEPTH)-1:0] wb_br_rob_tag_i,
    input  logic [$clog2(ROB_DEPTH)-1:0] wb_lsu_rob_tag_i,
    
    // Branch completion (separate from writeback - BNE completes but doesn't write)
    input  logic        complete_br_valid_i,
    input  logic [$clog2(ROB_DEPTH)-1:0] complete_br_rob_tag_i,

    // Dual commit outputs (broadcast to rename - NO ready signal, must always accept!)
    output logic        commit_valid_0_o,
    output logic        commit_writes_rd_0_o,
    output logic [6:0]  commit_dst_old_0_o,
    output logic [$clog2(ROB_DEPTH)-1:0] commit_rob_tag_0_o,

    output logic        commit_valid_1_o,
    output logic        commit_writes_rd_1_o,
    output logic [6:0]  commit_dst_old_1_o,
    output logic [$clog2(ROB_DEPTH)-1:0] commit_rob_tag_1_o,
    
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
    //   ALU0 > ALU1 > BR > LSU > PRF
    function automatic logic [31:0] op_with_bypass(
        input logic [PRF_BITS-1:0] addr,
        input logic [31:0]          prf_data
    );
        logic addr_nz;
        logic hit_alu, hit_alu1, hit_br, hit_lsu;
        logic oh_alu, oh_alu1, oh_br, oh_lsu, oh_prf;
        logic [31:0] data;
        begin
            addr_nz = (addr != '0);

            hit_alu  = wb_alu_valid_i  && addr_nz && (wb_alu_prf_i  == addr);
            hit_alu1 = wb_alu1_valid_i && addr_nz && (wb_alu1_prf_i == addr);
            hit_br   = wb_br_valid_i   && addr_nz && (wb_br_prf_i   == addr);
            hit_lsu  = wb_lsu_valid_i  && addr_nz && (wb_lsu_prf_i  == addr);

            oh_alu  = hit_alu;
            oh_alu1 = hit_alu1 && !hit_alu;
            oh_br   = hit_br   && !hit_alu && !hit_alu1;
            oh_lsu  = hit_lsu  && !hit_alu && !hit_alu1 && !hit_br;
            oh_prf  = !(oh_alu || oh_alu1 || oh_br || oh_lsu);

            data = ({32{oh_alu}}  & wb_alu_data_i)
                 | ({32{oh_alu1}} & wb_alu1_data_i)
                 | ({32{oh_br}}   & wb_br_data_i)
                 | ({32{oh_lsu}}  & wb_lsu_data_i)
                 | ({32{oh_prf}} & prf_data);

            op_with_bypass = data;
        end
    endfunction

    // ==================================
    // 1. Dual-entry pipeline buffer
    // ==================================
    // Stores up to 2 instructions (pkt0 and pkt1) from rename stage
    rename_pkt_t pb_pkt_0, pb_pkt_1;
    logic        pb_valid_0, pb_valid_1;
    logic        pb_ready;

    // Dual skid buffer using rename_dual_pkt_t
    logic        pb_dual_valid;
    rename_dual_pkt_t pb_dual_pkt;

    pipeline_skid_buffer_struct #(
        .T(rename_dual_pkt_t)
    ) u_skid_rn_dispatch (
        .clk       (clk),
        .reset     (reset),
        .flush     (recover_i),
        .valid_in  (rn_valid_i),
        .ready_in  (rn_ready_o),
        .data_in   (rn_pkt_i),
        .valid_out (pb_dual_valid),
        .ready_out (pb_ready),
        .data_out  (pb_dual_pkt)
    );

    // Unpack dual packet into two separate packets for dispatch logic
    assign pb_pkt_0   = pb_dual_pkt.pkt0;
    assign pb_pkt_1   = pb_dual_pkt.pkt1;
    assign pb_valid_0 = pb_dual_valid && pb_dual_pkt.valid0;
    assign pb_valid_1 = pb_dual_valid && pb_dual_pkt.valid1;

    // Alias for backward compatibility - current dispatch logic uses pb_pkt to refer to first instruction
    rename_pkt_t pb_pkt;
    logic        pb_valid;
    assign pb_pkt  = pb_pkt_0;
    assign pb_valid = pb_valid_0;

    // =====================
    // 2. PRF with busy scoreboard (replicated for timing)
    // =====================
    logic [PHYS_REGS-1:0] prf_busy_alu;
    logic [PHYS_REGS-1:0] prf_busy_br;
    logic [PHYS_REGS-1:0] prf_busy_lsu;

    // Raw PRF read data (no bypass inside PRF)
    logic [31:0] alu_src0_data_raw, alu_src1_data_raw;
    logic [31:0] alu1_src0_data_raw, alu1_src1_data_raw;
    logic [31:0] br_src0_data_raw,  br_src1_data_raw;
    logic [31:0] lsu_src0_data_raw, lsu_src1_data_raw;

    // Dual set_busy signals for dual-dispatch support
    logic        prf_set_busy_en_0, prf_set_busy_en_1;
    logic [6:0]  prf_set_busy_preg_0, prf_set_busy_preg_1;

    PRF #(
        .PHYS_REGS(PHYS_REGS)
    ) u_prf (
        .clk              (clk),
        .reset            (reset),
        // Writeback ports from EXUs (update PRF data and clear busy)
        .wb_alu_en_i      (wb_alu_valid_i),
        .wb_alu_preg_i    (wb_alu_prf_i),
        .wb_alu_data_i    (wb_alu_data_i),

        .wb_alu1_en_i     (wb_alu1_valid_i),
        .wb_alu1_preg_i   (wb_alu1_prf_i),
        .wb_alu1_data_i   (wb_alu1_data_i),

        .wb_br_en_i       (wb_br_valid_i),
        .wb_br_preg_i     (wb_br_prf_i),
        .wb_br_data_i     (wb_br_data_i),

        .wb_lsu_en_i      (wb_lsu_valid_i),
        .wb_lsu_preg_i    (wb_lsu_prf_i),
        .wb_lsu_data_i    (wb_lsu_data_i),

        // Dual busy scoreboard control for dual-dispatch
        .set_busy_en_0_i  (prf_set_busy_en_0),
        .set_busy_preg_0_i(prf_set_busy_preg_0),
        .set_busy_en_1_i  (prf_set_busy_en_1),
        .set_busy_preg_1_i(prf_set_busy_preg_1),
        .clr_busy_en_i    (1'b0),
        .clr_busy_preg_i  ('0),
        // Replicated busy outputs for each RS
        .busy_o           (prf_busy_alu),
        .busy_br_o        (prf_busy_br),
        .busy_lsu_o       (prf_busy_lsu),
        // Four issue read ports
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
        .iss2_r1_o        (lsu_src1_data_raw),

        .iss3_valid_i     (alu1_issue_valid_o),
        .iss3_src0_i      (alu1_issue_pkt_o.src0_prf),
        .iss3_src1_i      (alu1_issue_pkt_o.src1_prf),
        .iss3_r0_o        (alu1_src0_data_raw),
        .iss3_r1_o        (alu1_src1_data_raw)
    );

    // Apply same-cycle operand bypass here (moved out of PRF)
    assign alu_src0_data_o  = op_with_bypass(alu_issue_pkt_o.src0_prf,  alu_src0_data_raw);
    assign alu_src1_data_o  = op_with_bypass(alu_issue_pkt_o.src1_prf,  alu_src1_data_raw);
    assign alu1_src0_data_o = op_with_bypass(alu1_issue_pkt_o.src0_prf, alu1_src0_data_raw);
    assign alu1_src1_data_o = op_with_bypass(alu1_issue_pkt_o.src1_prf, alu1_src1_data_raw);
    assign br_src0_data_o   = op_with_bypass(br_issue_pkt_o.src0_prf,   br_src0_data_raw);
    assign br_src1_data_o   = op_with_bypass(br_issue_pkt_o.src1_prf,   br_src1_data_raw);
    assign lsu_src0_data_o  = op_with_bypass(lsu_issue_pkt_o.src0_prf,  lsu_src0_data_raw);
    assign lsu_src1_data_o  = op_with_bypass(lsu_issue_pkt_o.src1_prf,  lsu_src1_data_raw);

    // =====================
    // 3. Three reservation stations (each with 8 entries)
    // =====================
    // Forward declare ROB outputs needed by RS
    logic [$clog2(ROB_DEPTH)-1:0] rob_head_out;
    logic [$clog2(ROB_DEPTH)-1:0] rob_tail_cp_out;
    
    // ALU RS 0 - Uses "oldest among ready" policy with pipelined issue
    logic        alu_alloc_ready;
    logic        alu_alloc_valid;
    rs_pkt_t     alu_alloc_pkt;
    RS #(
        .PHYS_REGS  (PHYS_REGS),
        .ROB_ENTRIES(ROB_DEPTH)
    ) u_rs_alu0 (
        .clk                  (clk),
        .reset                (reset),
        .recover_i            (recover_i),
        .rob_head_i           (rob_head_out),
        .rob_tail_cp_i        (rob_tail_cp_out),
        .prf_busy_i           (prf_busy_alu),  // Use dedicated busy copy for ALU RS
        .wb_alu_valid_i       (wb_alu_valid_i),
        .wb_alu_prf_i         (wb_alu_prf_i),
        .wb_alu1_valid_i      (wb_alu1_valid_i),
        .wb_alu1_prf_i        (wb_alu1_prf_i),
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

    // ALU RS 1 (Second ALU) - Uses "oldest among ready" policy with pipelined issue
    logic        alu1_alloc_ready;
    logic        alu1_alloc_valid;
    rs_pkt_t     alu1_alloc_pkt;
    RS #(
        .PHYS_REGS  (PHYS_REGS),
        .ROB_ENTRIES(ROB_DEPTH)
    ) u_rs_alu1 (
        .clk                  (clk),
        .reset                (reset),
        .recover_i            (recover_i),
        .rob_head_i           (rob_head_out),
        .rob_tail_cp_i        (rob_tail_cp_out),
        .prf_busy_i           (prf_busy_alu),  // Share busy copy with ALU0
        .wb_alu_valid_i       (wb_alu_valid_i),
        .wb_alu_prf_i         (wb_alu_prf_i),
        .wb_alu1_valid_i      (wb_alu1_valid_i),
        .wb_alu1_prf_i        (wb_alu1_prf_i),
        .wb_br_valid_i        (wb_br_valid_i),
        .wb_br_prf_i          (wb_br_prf_i),
        .wb_lsu_valid_i       (wb_lsu_valid_i),
        .wb_lsu_prf_i         (wb_lsu_prf_i),
        .alloc_valid_i        (alu1_alloc_valid),
        .alloc_ready_o        (alu1_alloc_ready),
        .alloc_pkt_i          (alu1_alloc_pkt),
        .exu_ready_i          (alu1_exu_ready_i),
        .issue_valid_o        (alu1_issue_valid_o),
        .issue_pkt_o          (alu1_issue_pkt_o)
    );

    // BR RS - Uses "oldest among ready" policy with pipelined issue
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
        .prf_busy_i           (prf_busy_br),  // Use dedicated busy copy for Branch RS
        .wb_alu_valid_i       (wb_alu_valid_i),
        .wb_alu_prf_i         (wb_alu_prf_i),
        .wb_alu1_valid_i      (wb_alu1_valid_i),
        .wb_alu1_prf_i        (wb_alu1_prf_i),
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

    // LSU RS - Uses "oldest among ready" policy with pipelined issue (LSQ handles memory ordering)
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
        .prf_busy_i           (prf_busy_lsu),  // Use dedicated busy copy for LSU RS
        .wb_alu_valid_i       (wb_alu_valid_i),
        .wb_alu_prf_i         (wb_alu_prf_i),
        .wb_alu1_valid_i      (wb_alu1_valid_i),
        .wb_alu1_prf_i        (wb_alu1_prf_i),
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

    // Dual dispatch accept signals
    logic accept, accept_0, accept_1;
    logic dispatch_dual;  // True when both instructions can dispatch
    logic both_alu;       // Both instructions are ALU type
    logic structural_hazard; // Both instructions target same non-ALU RS

    // Check for structural hazards (both instructions need same RS type)
    assign both_alu = (pb_pkt_0.fu == 2'd0) && (pb_pkt_1.fu == 2'd0);
    assign structural_hazard = pb_valid_0 && pb_valid_1 &&
                               ((pb_pkt_0.fu == 2'd1) && (pb_pkt_1.fu == 2'd1)) || // Both branch
                               ((pb_pkt_0.fu == 2'd2) && (pb_pkt_1.fu == 2'd2));   // Both LSU

    // Determine if we can dual-dispatch:
    // - Both instructions valid
    // - Both are ALU (we have 2 ALU RS) OR no structural hazard
    // - Both target RS have space
    // - ROB has space for both
    assign dispatch_dual = pb_valid_0 && pb_valid_1 &&
                          both_alu &&                  // Currently only dual-dispatch ALU instructions
                          (alu_alloc_ready && alu1_alloc_ready) && // Both ALU RS ready
                          rob_ready;                   // ROB can accept both

    // Accept logic for each instruction
    assign accept   = pb_valid && pb_ready;    // Backward compatibility
    assign accept_0 = pb_valid_0 && pb_ready;  // First instruction always accepted if valid and ready
    assign accept_1 = dispatch_dual;            // Second only if dual-dispatch conditions met

    ROB #(.ROB_ENTRIES(ROB_DEPTH)) u_rob (
        .clk                  (clk),
        .reset                (reset),
        .recover_i            (recover_i),
        .mispredict_rob_tag_i (wb_br_rob_tag_i),  // ROB tag of mispredicting branch
        // Dual allocation
        .valid_0_i            (accept_0),
        .is_branch_0_i        (pb_pkt_0.is_branch),
        .writes_rd_0_i        (pb_pkt_0.writes_rd),
        .dst_new_0_i          (pb_pkt_0.dst_prf_new),
        .dst_old_0_i          (pb_pkt_0.dst_prf_old),
        .rob_tag_0_i          (pb_pkt_0.rob_tag),
        .tag_0_o              (rob_tail_idx),
        .ready_0_o            (rob_ready),

        .valid_1_i            (accept_1),
        .is_branch_1_i        (pb_pkt_1.is_branch),
        .writes_rd_1_i        (pb_pkt_1.writes_rd),
        .dst_new_1_i          (pb_pkt_1.dst_prf_new),
        .dst_old_1_i          (pb_pkt_1.dst_prf_old),
        .rob_tag_1_i          (pb_pkt_1.rob_tag),
        .tag_1_o              (),  // Not used in current implementation
        .ready_1_o            (),  // Not used in current implementation

        .full_o               (),
        .head_o               (rob_head_out),
        .tail_cp_o            (rob_tail_cp_out),
        // Complete signals from EXUs
        .complete_alu_valid_i (wb_alu_valid_i),
        .complete_alu_tag_i   (wb_alu_rob_tag_i),
        .complete_alu1_valid_i(wb_alu1_valid_i),
        .complete_alu1_tag_i  (wb_alu1_rob_tag_i),
        .complete_br_valid_i  (complete_br_valid_i),   // Use dedicated completion signal
        .complete_br_tag_i    (complete_br_rob_tag_i), // Use dedicated completion tag
        .complete_lsu_valid_i (wb_lsu_valid_i),
        .complete_lsu_tag_i   (wb_lsu_rob_tag_i),
        // Dual commit outputs
        .commit_valid_0_o       (commit_valid_0_o),
        .commit_writes_rd_0_o   (commit_writes_rd_0_o),
        .commit_dst_old_0_o     (commit_dst_old_0_o),
        .commit_rob_tag_0_o     (commit_rob_tag_0_o),
        .commit_valid_1_o       (commit_valid_1_o),
        .commit_writes_rd_1_o   (commit_writes_rd_1_o),
        .commit_dst_old_1_o     (commit_dst_old_1_o),
        .commit_rob_tag_1_o     (commit_rob_tag_1_o)
    );

    // =====================
    // 5. Allocation control and packet assembly (combinational)
    // =====================
    // ALU round-robin allocation pointer (0 = prefer ALU0, 1 = prefer ALU1)
    // Only used for single-issue ALU instructions; dual-issue always uses both
    logic alu_rr_ptr;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            alu_rr_ptr <= 1'b0;
        end else if (recover_i) begin
            // Reset to 0 on branch misprediction recovery
            alu_rr_ptr <= 1'b0;
        end else if (accept_0 && (pb_pkt_0.fu == 2'd0) && !dispatch_dual) begin
            // Toggle round-robin pointer only for single ALU allocation
            alu_rr_ptr <= ~alu_rr_ptr;
        end
    end

    // Determine whether the target RS has available slots for both instructions
    logic target_rs_ready_0, target_rs_ready_1;
    logic is_store_instr_0, is_store_instr_1;
    logic prefer_alu0;  // Which ALU RS to try first based on round-robin

    // micro_op[1] = sw (store operation)
    assign is_store_instr_0 = (pb_pkt_0.fu == 2'd2) && pb_pkt_0.micro_op[1];
    assign is_store_instr_1 = (pb_pkt_1.fu == 2'd2) && pb_pkt_1.micro_op[1];

    // For each instruction, check if target RS has space
    always_comb begin
        prefer_alu0 = (alu_rr_ptr == 1'b0);

        // Instruction 0 RS readiness
        unique case (pb_pkt_0.fu)
            2'd0: target_rs_ready_0 = alu_alloc_ready | alu1_alloc_ready;  // Either ALU RS
            2'd1: target_rs_ready_0 = br_alloc_ready;
            2'd2: target_rs_ready_0 = lsu_alloc_ready;
            default: target_rs_ready_0 = 1'b0;
        endcase

        // Instruction 1 RS readiness (for dual-dispatch, needs separate ALU RS)
        unique case (pb_pkt_1.fu)
            2'd0: target_rs_ready_1 = alu_alloc_ready && alu1_alloc_ready;  // Need BOTH ALU RS for dual
            2'd1: target_rs_ready_1 = br_alloc_ready;
            2'd2: target_rs_ready_1 = lsu_alloc_ready;
            default: target_rs_ready_1 = 1'b0;
        endcase
    end

    // Pipeline buffer ready logic:
    // For dual-dispatch: ROB ready AND both RS ready AND store constraints
    // For single-dispatch: ROB ready AND first RS ready AND store constraints
    logic pb_ready_dual, pb_ready_single;

    assign pb_ready_dual   = rob_ready &&
                            target_rs_ready_1 &&  // Includes both ALU RS ready check
                            (!is_store_instr_0 || lsq_alloc_ready_i) &&
                            (!is_store_instr_1 || lsq_alloc_ready_i);

    assign pb_ready_single = rob_ready &&
                            target_rs_ready_0 &&
                            (!is_store_instr_0 || lsq_alloc_ready_i);

    // pb_ready true if we can accept at least instruction 0
    assign pb_ready = dispatch_dual ? pb_ready_dual : pb_ready_single;

    // Dual-issue allocation logic
    // Build RS packets and set busy for both instructions
    always_comb begin
        // Default assignments
        alu_alloc_valid  = 1'b0;
        alu1_alloc_valid = 1'b0;
        br_alloc_valid   = 1'b0;
        lsu_alloc_valid  = 1'b0;
        alu_alloc_pkt    = '0;
        alu1_alloc_pkt   = '0;
        br_alloc_pkt     = '0;
        lsu_alloc_pkt    = '0;
        prf_set_busy_en_0  = 1'b0;
        prf_set_busy_preg_0 = '0;
        prf_set_busy_en_1  = 1'b0;
        prf_set_busy_preg_1 = '0;

        // ===== Instruction 0 allocation =====
        if (accept_0) begin
            rs_pkt_t pkt0;
            pkt0.valid       = 1'b1;
            pkt0.micro_op    = pb_pkt_0.micro_op;
            pkt0.dst_prf     = pb_pkt_0.dst_prf_new;
            pkt0.src0_prf    = pb_pkt_0.src0_prf;
            pkt0.src0_ready  = 1'b0; // RS recomputes readiness
            pkt0.src1_prf    = pb_pkt_0.src1_prf;
            pkt0.src1_ready  = 1'b0;
            pkt0.imm         = pb_pkt_0.imm;
            pkt0.fu          = pb_pkt_0.fu;
            pkt0.rob_tag     = pb_pkt_0.rob_tag;
            pkt0.pc          = pb_pkt_0.pc;
            pkt0.pred_hit    = pb_pkt_0.pred_hit;
            pkt0.pred_taken  = pb_pkt_0.pred_taken;
            pkt0.pred_target = pb_pkt_0.pred_target;

            // Allocate instruction 0 to appropriate RS
            if (dispatch_dual) begin
                // Dual-dispatch: allocate first ALU to ALU0
                alu_alloc_valid = 1'b1;
                alu_alloc_pkt   = pkt0;
            end else begin
                // Single-dispatch: use round-robin for ALU
                unique case (pb_pkt_0.fu)
                    2'd0: begin
                        // ALU instruction - round-robin with fallback
                        if (prefer_alu0) begin
                            if (alu_alloc_ready) begin
                                alu_alloc_valid = 1'b1;
                                alu_alloc_pkt   = pkt0;
                            end else if (alu1_alloc_ready) begin
                                alu1_alloc_valid = 1'b1;
                                alu1_alloc_pkt   = pkt0;
                            end
                        end else begin
                            if (alu1_alloc_ready) begin
                                alu1_alloc_valid = 1'b1;
                                alu1_alloc_pkt   = pkt0;
                            end else if (alu_alloc_ready) begin
                                alu_alloc_valid = 1'b1;
                                alu_alloc_pkt   = pkt0;
                            end
                        end
                    end
                    2'd1: begin
                        br_alloc_valid = 1'b1;
                        br_alloc_pkt   = pkt0;
                    end
                    2'd2: begin
                        lsu_alloc_valid = 1'b1;
                        lsu_alloc_pkt   = pkt0;
                    end
                    default: begin
                        // No RS selected
                    end
                endcase
            end

            // Mark destination busy for instruction 0 (use port 0)
            if (pb_pkt_0.writes_rd && (pb_pkt_0.dst_prf_new != '0)) begin
                prf_set_busy_en_0   = 1'b1;
                prf_set_busy_preg_0 = pb_pkt_0.dst_prf_new[6:0];
            end
        end

        // ===== Instruction 1 allocation (only in dual-dispatch mode) =====
        if (accept_1) begin
            rs_pkt_t pkt1;
            pkt1.valid       = 1'b1;
            pkt1.micro_op    = pb_pkt_1.micro_op;
            pkt1.dst_prf     = pb_pkt_1.dst_prf_new;
            pkt1.src0_prf    = pb_pkt_1.src0_prf;
            pkt1.src0_ready  = 1'b0;
            pkt1.src1_prf    = pb_pkt_1.src1_prf;
            pkt1.src1_ready  = 1'b0;
            pkt1.imm         = pb_pkt_1.imm;
            pkt1.fu          = pb_pkt_1.fu;
            pkt1.rob_tag     = pb_pkt_1.rob_tag;
            pkt1.pc          = pb_pkt_1.pc;
            pkt1.pred_hit    = pb_pkt_1.pred_hit;
            pkt1.pred_taken  = pb_pkt_1.pred_taken;
            pkt1.pred_target = pb_pkt_1.pred_target;

            // In dual-dispatch mode, always allocate second ALU to ALU1
            alu1_alloc_valid = 1'b1;
            alu1_alloc_pkt   = pkt1;

            // Mark destination busy for instruction 1 (use port 1)
            if (pb_pkt_1.writes_rd && (pb_pkt_1.dst_prf_new != '0)) begin
                prf_set_busy_en_1   = 1'b1;
                prf_set_busy_preg_1 = pb_pkt_1.dst_prf_new[6:0];
            end
        end
    end

    // ROB head/tail outputs for LSQ
    assign rob_head_o    = rob_head_out;
    assign rob_tail_cp_o = rob_tail_cp_out;
    
    // Store allocation: when a store dispatches to LSU RS
    // micro_op[1] = sw (store operation)
    assign store_alloc_valid_o   = lsu_alloc_valid && lsu_alloc_pkt.micro_op[1];
    assign store_alloc_rob_tag_o = lsu_alloc_pkt.rob_tag;  // Use instruction's actual ROB tag, not tail pointer!
    
    // Commit ROB tag output (commit always happens at head)
    assign commit_rob_tag_o = rob_head_out;

endmodule
