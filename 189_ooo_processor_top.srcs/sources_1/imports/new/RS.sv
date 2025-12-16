`timescale 1ns / 1ps

import cpu_pkg::*;

// Reservation Station - All RS use "oldest among ready" issue policy
// Memory ordering is handled by LSQ, not RS
module RS #(
  parameter int PHYS_REGS   = 128,
  parameter int ROB_ENTRIES = 16
)(
  input  logic clk, reset,
  input  logic recover_i,
  input  logic [$clog2(ROB_ENTRIES)-1:0] rob_head_i,
  input  logic [$clog2(ROB_ENTRIES)-1:0] rob_tail_cp_i,

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

  // ---------- Allocation: priority decode to find a free slot ----------
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

  // ---------- Ready mask and age distance ----------
  logic [7:0] ready_mask;
  logic [$clog2(ROB_ENTRIES)-1:0] age_dist [8];
  
  always_comb begin
    for (int j = 0; j < 8; j++) begin
      logic src0_ready;
      logic src1_ready;

      if (slots[j].valid) begin
        age_dist[j] = slots[j].pkt.rob_tag - rob_head_i;

        src0_ready = !prf_busy_i[slots[j].pkt.src0_prf] ||
                     ((wb_alu_valid_i && (wb_alu_prf_i == slots[j].pkt.src0_prf) && (wb_alu_prf_i != 7'd0))) ||
                     ((wb_br_valid_i  && (wb_br_prf_i  == slots[j].pkt.src0_prf) && (wb_br_prf_i  != 7'd0))) ||
                     ((wb_lsu_valid_i && (wb_lsu_prf_i == slots[j].pkt.src0_prf) && (wb_lsu_prf_i != 7'd0)));

        src1_ready = !prf_busy_i[slots[j].pkt.src1_prf] ||
                     ((wb_alu_valid_i && (wb_alu_prf_i == slots[j].pkt.src1_prf) && (wb_alu_prf_i != 7'd0))) ||
                     ((wb_br_valid_i  && (wb_br_prf_i  == slots[j].pkt.src1_prf) && (wb_br_prf_i  != 7'd0))) ||
                     ((wb_lsu_valid_i && (wb_lsu_prf_i == slots[j].pkt.src1_prf) && (wb_lsu_prf_i != 7'd0)));
      end else begin
        age_dist[j] = '1;
        src0_ready  = 1'b0;
        src1_ready  = 1'b0;
      end

      ready_mask[j] = slots[j].valid && src0_ready && src1_ready;
    end
  end
  
  // ---------- Issue selection: oldest among ready ----------
  logic [3:0] issue_idx;
  logic       has_ready;
  
  always_comb begin
    issue_idx = 4'hF;
    has_ready = 1'b0;

    // Find oldest ready entry
    for (int i = 0; i < 8; i++) begin
      if (ready_mask[i]) begin
        if (!has_ready || (age_dist[i] < age_dist[issue_idx])) begin
          issue_idx = i[3:0];
          has_ready = 1'b1;
        end
      end
    end
  end

  assign issue_valid_o = has_ready & exu_ready_i & !recover_i;
  assign issue_pkt_o   = has_ready ? slots[issue_idx].pkt : '0;

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
