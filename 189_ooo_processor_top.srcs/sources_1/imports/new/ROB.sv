`timescale 1ns / 1ps

module ROB #(
  parameter integer ROB_ENTRIES = 16
)(
  input  logic clk, reset,
  input  logic recover_i,
  input  logic [$clog2(ROB_ENTRIES)-1:0] mispredict_rob_tag_i, // ROB tag of mispredicting branch

  // Dual allocation from dispatch
  input  logic valid_0_i,
  input  logic is_branch_0_i,
  input  logic writes_rd_0_i,
  input  logic [6:0] dst_new_0_i,
  input  logic [6:0] dst_old_0_i,
  input  logic [$clog2(ROB_ENTRIES)-1:0] rob_tag_0_i,
  output logic [$clog2(ROB_ENTRIES)-1:0] tag_0_o,
  output logic ready_0_o,

  input  logic valid_1_i,
  input  logic is_branch_1_i,
  input  logic writes_rd_1_i,
  input  logic [6:0] dst_new_1_i,
  input  logic [6:0] dst_old_1_i,
  input  logic [$clog2(ROB_ENTRIES)-1:0] rob_tag_1_i,
  output logic [$clog2(ROB_ENTRIES)-1:0] tag_1_o,
  output logic ready_1_o,

  output logic full_o,
  
  // Head and recovery point outputs for RS speculation check
  output logic [$clog2(ROB_ENTRIES)-1:0] head_o,
  output logic [$clog2(ROB_ENTRIES)-1:0] tail_cp_o,

  // Complete signals from execution units (mark instruction as done)
  input  logic        complete_alu_valid_i,
  input  logic [$clog2(ROB_ENTRIES)-1:0] complete_alu_tag_i,
  input  logic        complete_alu1_valid_i,
  input  logic [$clog2(ROB_ENTRIES)-1:0] complete_alu1_tag_i,
  input  logic        complete_br_valid_i,
  input  logic [$clog2(ROB_ENTRIES)-1:0] complete_br_tag_i,
  input  logic        complete_lsu_valid_i,
  input  logic [$clog2(ROB_ENTRIES)-1:0] complete_lsu_tag_i,

  // Dual commit outputs (broadcast to rename/free_list)
  // NOTE: Commit has valid but NO ready - downstream must always accept!
  output logic        commit_valid_0_o,
  output logic        commit_writes_rd_0_o,
  output logic [6:0]  commit_dst_old_0_o,     // Old PRF to return to free list
  output logic [$clog2(ROB_ENTRIES)-1:0] commit_rob_tag_0_o,

  output logic        commit_valid_1_o,
  output logic        commit_writes_rd_1_o,
  output logic [6:0]  commit_dst_old_1_o,
  output logic [$clog2(ROB_ENTRIES)-1:0] commit_rob_tag_1_o
);
  typedef struct packed {
    logic        valid;
    logic        complete;      // 0 before execute/writeback, set to 1 when finished
    logic        is_branch;
    logic        writes_rd;
    logic [6:0]  dst_prf_new, dst_prf_old;
    logic [$clog2(ROB_ENTRIES)-1:0] rob_tag;
  } rob_entry_t;

  rob_entry_t rob[ROB_ENTRIES];
  logic [$clog2(ROB_ENTRIES)-1:0] head, tail;
  // one-slot-empty scheme: full when next_tail == head, empty when head == tail
  logic [$clog2(ROB_ENTRIES)-1:0] next_tail, next_tail_2;

  // Compute next_tail and next_tail+2 for dual allocation
  assign next_tail   = (tail == ROB_ENTRIES-1) ? '0 : (tail + 1'b1);
  assign next_tail_2 = (tail >= ROB_ENTRIES-2) ? (tail + 2 - ROB_ENTRIES) : (tail + 2);

  // Fullness checking for dual allocation
  assign full_o      = (next_tail == head);
  assign ready_0_o   = !full_o;  // At least 1 slot available
  assign ready_1_o   = (next_tail_2 != head) && (next_tail != head);  // At least 2 slots available

  // Tag outputs
  assign tag_0_o     = tail;
  assign tag_1_o     = next_tail;
  
  // Calculate recovery point directly from mispredicting branch's ROB tag
  logic [$clog2(ROB_ENTRIES)-1:0] recovery_tail_cp;
  assign recovery_tail_cp = mispredict_rob_tag_i + 1'b1;  // Auto-wraps due to bit width
  
  // Output head and recovery point for RS speculation check
  assign head_o      = head;
  assign tail_cp_o   = recovery_tail_cp;

  // =====================
  // Dual commit logic (in-order, from head and head+1)
  // =====================
  logic [$clog2(ROB_ENTRIES)-1:0] head_next;
  assign head_next = (head == ROB_ENTRIES-1) ? '0 : (head + 1'b1);

  logic head_can_commit_0, head_can_commit_1, commit_dual;
  assign head_can_commit_0 = rob[head].valid && rob[head].complete && !recover_i;
  assign head_can_commit_1 = rob[head_next].valid && rob[head_next].complete && !recover_i;
  assign commit_dual       = head_can_commit_0 && head_can_commit_1;

  // First commit (always from head if ready)
  assign commit_valid_0_o     = head_can_commit_0;
  assign commit_writes_rd_0_o = rob[head].writes_rd;
  assign commit_dst_old_0_o   = rob[head].dst_prf_old;
  assign commit_rob_tag_0_o   = rob[head].rob_tag;

  // Second commit (only if dual commit)
  assign commit_valid_1_o     = commit_dual;
  assign commit_writes_rd_1_o = rob[head_next].writes_rd;
  assign commit_dst_old_1_o   = rob[head_next].dst_prf_old;
  assign commit_rob_tag_1_o   = rob[head_next].rob_tag;

  logic [4:0] i;
  always_ff @(posedge clk or posedge reset) begin
    if(reset) begin
      head <= '0; 
      tail <= '0;
      for (i=0;i<ROB_ENTRIES;i++) rob[i] <= '0;
    end else if (recover_i) begin
      // Roll back tail to the recovery point (mispredict_tag + 1)
      // This clears all instructions allocated after the mispredicting branch
      // Keep entries in [head .. recovery_tail_cp) and invalidate entries in [recovery_tail_cp .. tail)
      for (i=0;i<ROB_ENTRIES;i++) begin
        logic in_speculative_range;
        logic [$clog2(ROB_ENTRIES)-1:0] idx;
        idx = i[$clog2(ROB_ENTRIES)-1:0];
        
        // Check if this entry is in the speculative range [recovery_tail_cp, tail)
        if (recovery_tail_cp <= tail) begin
          // Non-wrapping speculative range
          in_speculative_range = (idx >= recovery_tail_cp) && (idx < tail);
        end else begin
          // Wrapping speculative range: [recovery_tail_cp, ROB_SIZE) + [0, tail)
          in_speculative_range = (idx >= recovery_tail_cp) || (idx < tail);
        end
        
        // Invalidate if in speculative range
        if (in_speculative_range) begin
          rob[i].valid <= 1'b0;
        end
      end
      
      tail <= recovery_tail_cp;

      // This handles in-flight operations that complete during the recovery cycle
      if (complete_alu_valid_i && rob[complete_alu_tag_i].valid) begin
        rob[complete_alu_tag_i].complete <= 1'b1;
      end
      if (complete_alu1_valid_i && rob[complete_alu1_tag_i].valid) begin
        rob[complete_alu1_tag_i].complete <= 1'b1;
      end
      if (complete_br_valid_i && rob[complete_br_tag_i].valid) begin
        rob[complete_br_tag_i].complete <= 1'b1;
      end
      if (complete_lsu_valid_i && rob[complete_lsu_tag_i].valid) begin
        rob[complete_lsu_tag_i].complete <= 1'b1;
      end
    end else begin
      // =====================
      // Mark instructions as complete (from EXU writeback)
      // =====================
      if (complete_alu_valid_i && rob[complete_alu_tag_i].valid) begin
        rob[complete_alu_tag_i].complete <= 1'b1;
      end
      if (complete_alu1_valid_i && rob[complete_alu1_tag_i].valid) begin
        rob[complete_alu1_tag_i].complete <= 1'b1;
      end
      if (complete_br_valid_i && rob[complete_br_tag_i].valid) begin
        rob[complete_br_tag_i].complete <= 1'b1;
      end
      if (complete_lsu_valid_i && rob[complete_lsu_tag_i].valid) begin
        rob[complete_lsu_tag_i].complete <= 1'b1;
      end

      // =====================
      // Dual commit (dequeue from head, in-order)
      // =====================
      if (commit_dual) begin
        // Commit both head and head+1
        rob[head].valid <= 1'b0;
        rob[head].complete <= 1'b0;
        rob[head_next].valid <= 1'b0;
        rob[head_next].complete <= 1'b0;
        // Advance head by 2
        head <= (head >= ROB_ENTRIES-2) ? (head + 2 - ROB_ENTRIES) : (head + 2);
      end else if (head_can_commit_0) begin
        // Commit only head
        rob[head].valid <= 1'b0;
        rob[head].complete <= 1'b0;
        head <= head_next;
      end

      // =====================
      // Dual Allocation (enqueue at tail and tail+1)
      // =====================
      logic alloc_dual;
      alloc_dual = valid_0_i && valid_1_i && ready_0_o && ready_1_o;

      if (alloc_dual) begin
        // Allocate both instructions
        rob[tail].valid       <= 1'b1;
        rob[tail].complete    <= 1'b0;
        rob[tail].is_branch   <= is_branch_0_i;
        rob[tail].writes_rd   <= writes_rd_0_i;
        rob[tail].dst_prf_new <= dst_new_0_i;
        rob[tail].dst_prf_old <= dst_old_0_i;
        rob[tail].rob_tag     <= rob_tag_0_i;

        rob[next_tail].valid       <= 1'b1;
        rob[next_tail].complete    <= 1'b0;
        rob[next_tail].is_branch   <= is_branch_1_i;
        rob[next_tail].writes_rd   <= writes_rd_1_i;
        rob[next_tail].dst_prf_new <= dst_new_1_i;
        rob[next_tail].dst_prf_old <= dst_old_1_i;
        rob[next_tail].rob_tag     <= rob_tag_1_i;

        tail <= next_tail_2;
      end else if (valid_0_i && ready_0_o) begin
        // Allocate only first instruction
        rob[tail].valid       <= 1'b1;
        rob[tail].complete    <= 1'b0;
        rob[tail].is_branch   <= is_branch_0_i;
        rob[tail].writes_rd   <= writes_rd_0_i;
        rob[tail].dst_prf_new <= dst_new_0_i;
        rob[tail].dst_prf_old <= dst_old_0_i;
        rob[tail].rob_tag     <= rob_tag_0_i;

        tail <= next_tail;
      end
    end
  end
endmodule