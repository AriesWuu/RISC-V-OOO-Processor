`timescale 1ns / 1ps

module ROB #(
  parameter integer ROB_ENTRIES = 16
)(
  input  logic clk, reset,
  input  logic recover_i,
  input  logic [$clog2(ROB_ENTRIES)-1:0] mispredict_rob_tag_i, // ROB tag of mispredicting branch

  // Allocation from dispatch
  input  logic valid_i,
  output logic ready_o,
  input  logic is_branch_i,
  input  logic writes_rd_i,
  input  logic [6:0] dst_new_i,
  input  logic [6:0] dst_old_i,
  input  logic [$clog2(ROB_ENTRIES)-1:0] rob_tag_i,
  output logic [$clog2(ROB_ENTRIES)-1:0] tag_o,
  output logic full_o,
  
  // Head and recovery point outputs for RS speculation check
  output logic [$clog2(ROB_ENTRIES)-1:0] head_o,
  output logic [$clog2(ROB_ENTRIES)-1:0] tail_cp_o,

  // Complete signals from execution units (mark instruction as done)
  input  logic        complete_alu_valid_i,
  input  logic [$clog2(ROB_ENTRIES)-1:0] complete_alu_tag_i,
  input  logic        complete_br_valid_i,
  input  logic [$clog2(ROB_ENTRIES)-1:0] complete_br_tag_i,
  input  logic        complete_lsu_valid_i,
  input  logic [$clog2(ROB_ENTRIES)-1:0] complete_lsu_tag_i,

  // Commit outputs (broadcast to rename/free_list)
  // NOTE: Commit has valid but NO ready - downstream must always accept!
  output logic        commit_valid_o,
  output logic        commit_writes_rd_o,
  output logic [6:0]  commit_dst_old_o     // Old PRF to return to free list
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
  logic [$clog2(ROB_ENTRIES)-1:0] next_tail; // tail+1

  // Compute next_tail before checking fullness
  assign next_tail   = (tail == ROB_ENTRIES-1) ? '0 : (tail + 1'b1);
  assign full_o      = (next_tail == head);
  assign ready_o     = !full_o;
  assign tag_o       = tail;
  
  // Calculate recovery point directly from mispredicting branch's ROB tag
  logic [$clog2(ROB_ENTRIES)-1:0] recovery_tail_cp;
  assign recovery_tail_cp = mispredict_rob_tag_i + 1'b1;  // Auto-wraps due to bit width
  
  // Output head and recovery point for RS speculation check
  assign head_o      = head;
  assign tail_cp_o   = recovery_tail_cp;

  // =====================
  // Commit logic (in-order, from head)
  // =====================
  // Commit when head entry is valid AND complete AND not recovering
  // NOTE: commit_valid_o is output-only, no ready signal - downstream MUST accept!
  logic head_can_commit;
  assign head_can_commit   = rob[head].valid && rob[head].complete && !recover_i;
  assign commit_valid_o    = head_can_commit;
  assign commit_writes_rd_o= rob[head].writes_rd;
  assign commit_dst_old_o  = rob[head].dst_prf_old;

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
      if (complete_br_valid_i && rob[complete_br_tag_i].valid) begin
        rob[complete_br_tag_i].complete <= 1'b1;
      end
      if (complete_lsu_valid_i && rob[complete_lsu_tag_i].valid) begin
        rob[complete_lsu_tag_i].complete <= 1'b1;
      end

      // =====================
      // Commit (dequeue from head, in-order)
      // =====================
      if (head_can_commit) begin
        rob[head].valid <= 1'b0;
        rob[head].complete <= 1'b0;
        head <= (head == ROB_ENTRIES-1) ? '0 : (head + 1'b1);
      end

      // =====================
      // Allocate (enqueue at tail)
      // =====================
      if (valid_i && ready_o) begin
        rob[tail].valid      <= 1'b1;
        rob[tail].complete   <= 1'b0;
        rob[tail].is_branch  <= is_branch_i;
        rob[tail].writes_rd  <= writes_rd_i;
        rob[tail].dst_prf_new<= dst_new_i;
        rob[tail].dst_prf_old<= dst_old_i;
        rob[tail].rob_tag    <= rob_tag_i;

        tail  <= (tail == ROB_ENTRIES-1) ? '0 : (tail + 1'b1);
      end
    end
  end
endmodule