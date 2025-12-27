`timescale 1ns / 1ps

import cpu_pkg::*;

// Reservation Station - PIPELINED issue selection for timing optimization
// Stage 1: Wakeup + Ready detection (combinational, registered)
// Stage 2: Issue selection from registered ready mask
// Memory ordering is handled by LSQ, not RS
module RS #(
  parameter int PHYS_REGS   = 128,
  parameter int ROB_ENTRIES = 16
)(
  input  logic clk, reset,
  input  logic recover_i,
  input  logic [$clog2(ROB_ENTRIES)-1:0] rob_head_i,
  input  logic [$clog2(ROB_ENTRIES)-1:0] rob_tail_cp_i,

  // Registered busy vector from PRF (reduces fanout)
  input  logic [PHYS_REGS-1:0] prf_busy_i,

  // Same-cycle wakeup from writeback buses
  input  logic        wb_alu_valid_i,
  input  logic [6:0]  wb_alu_prf_i,
  input  logic        wb_br_valid_i,
  input  logic [6:0]  wb_br_prf_i,
  input  logic        wb_lsu_valid_i,
  input  logic [6:0]  wb_lsu_prf_i,

  // Allocation from dispatch
  input  logic      alloc_valid_i,
  output logic      alloc_ready_o,
  input  rs_pkt_t   alloc_pkt_i,

  // Issue to EXU
  input  logic      exu_ready_i,
  output logic      issue_valid_o,
  output rs_pkt_t   issue_pkt_o
);

  typedef struct packed {
    logic    valid;
    rs_pkt_t pkt;
  } slot_t;

  slot_t slots[8];

  // ========================================================
  // STAGE 1: Wakeup + Ready detection (per-slot, pipelined)
  // ========================================================
  
  // Registered ready status per slot (updated each cycle)
  logic [7:0] slot_src0_ready_q;
  logic [7:0] slot_src1_ready_q;
  logic [7:0] ready_mask_q;
  logic [$clog2(ROB_ENTRIES)-1:0] age_dist_q [8];
  
  // Combinational wakeup detection
  // Check if source register will be ready NEXT cycle (from writeback)
  function automatic logic check_ready(
    input logic [6:0] src_prf,
    input logic [PHYS_REGS-1:0] busy_vec
  );
    logic ready;
    begin
      ready = (src_prf == 7'd0) ? 1'b1 : !busy_vec[src_prf];
      // Same-cycle wakeup from writeback
      if (wb_alu_valid_i && src_prf == wb_alu_prf_i && src_prf != 7'd0) ready = 1'b1;
      if (wb_br_valid_i  && src_prf == wb_br_prf_i  && src_prf != 7'd0) ready = 1'b1;
      if (wb_lsu_valid_i && src_prf == wb_lsu_prf_i && src_prf != 7'd0) ready = 1'b1;
      check_ready = ready;
    end
  endfunction

  // Register ready status (PIPELINE STAGE 1)
  always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
      slot_src0_ready_q <= '0;
      slot_src1_ready_q <= '0;
      ready_mask_q      <= '0;
      for (int j = 0; j < 8; j++) age_dist_q[j] <= '1;
    end else if (recover_i) begin
      ready_mask_q <= '0;
    end else begin
      for (int j = 0; j < 8; j++) begin
        if (slots[j].valid) begin
          slot_src0_ready_q[j] <= check_ready(slots[j].pkt.src0_prf, prf_busy_i);
          slot_src1_ready_q[j] <= check_ready(slots[j].pkt.src1_prf, prf_busy_i);
          age_dist_q[j]        <= slots[j].pkt.rob_tag - rob_head_i;
          ready_mask_q[j]      <= check_ready(slots[j].pkt.src0_prf, prf_busy_i) &&
                                  check_ready(slots[j].pkt.src1_prf, prf_busy_i);
        end else begin
          slot_src0_ready_q[j] <= 1'b0;
          slot_src1_ready_q[j] <= 1'b0;
          age_dist_q[j]        <= '1;
          ready_mask_q[j]      <= 1'b0;
        end
      end
    end
  end

  // ========================================================
  // Allocation: priority decode to find a free slot
  // ========================================================
  logic [7:0] free_mask;
  for (genvar i = 0; i < 8; i++) begin : g_free
    assign free_mask[i] = !slots[i].valid;
  end

  // Priority decoder: return index of first '1', or 4'hF if none
  function automatic [3:0] pdec_first1(input logic [7:0] m);
    logic       found;
    logic [3:0] idx;
    logic [3:0] i;
    begin
      found = 1'b0;
      idx   = 4'hF;
      for (i = 0; i < 8; i = i + 1) begin
        if (!found && m[i]) begin
          idx   = i;
          found = 1'b1;
        end
      end
      pdec_first1 = idx;
    end
  endfunction

  logic [3:0] alloc_idx;
  assign alloc_idx     = pdec_first1(free_mask);
  assign alloc_ready_o = (alloc_idx != 4'hF);

  // ========================================================
  // STAGE 2: Issue selection (from registered ready mask)
  // TIMING OPTIMIZED: Use simple priority encoder instead of age comparison
  // This trades "oldest-first" for "lowest-index-first" to reduce logic depth
  // For most workloads, the IPC impact is minimal
  // ========================================================
  
  logic [3:0] issue_idx;
  logic       has_ready;
  
  // Simple priority encoder - select first ready slot (lowest index)
  // This is much faster than age comparison (reduces ~10 logic levels)
  always_comb begin
    issue_idx = 4'hF;
    has_ready = 1'b0;
    
    for (int i = 0; i < 8; i++) begin
      if (!has_ready && ready_mask_q[i] && slots[i].valid) begin
        issue_idx = i[3:0];
        has_ready = 1'b1;
      end
    end
  end

  assign issue_valid_o = has_ready & exu_ready_i & !recover_i;
  assign issue_pkt_o   = (has_ready && issue_idx < 4'd8) ? slots[issue_idx].pkt : '0;

  // ---------- Speculation check ----------
  function automatic logic is_speculative(
    input logic [$clog2(ROB_ENTRIES)-1:0] rob_tag,
    input logic [$clog2(ROB_ENTRIES)-1:0] head,
    input logic [$clog2(ROB_ENTRIES)-1:0] tail_cp
  );
    logic in_valid_range;
    begin
      if (head <= tail_cp)
        in_valid_range = (rob_tag >= head) && (rob_tag < tail_cp);
      else
        in_valid_range = (rob_tag >= head) || (rob_tag < tail_cp);
      is_speculative = !in_valid_range;
    end
  endfunction

  // ---------- State update ----------
  logic [3:0] k;
  always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
      for (k = 0; k < 8; k++) slots[k] <= '0;
    end else if (recover_i) begin
      for (k = 0; k < 8; k++) begin
        if (slots[k].valid && is_speculative(slots[k].pkt.rob_tag, rob_head_i, rob_tail_cp_i))
          slots[k] <= '0;
      end
    end else begin
      // Allocate
      if (alloc_valid_i && alloc_ready_o) begin
        slots[alloc_idx].valid <= 1'b1;
        slots[alloc_idx].pkt   <= alloc_pkt_i;
      end
      // Issue consumption
      if (issue_valid_o) begin
        slots[issue_idx].valid <= 1'b0;
      end
    end
  end

endmodule
