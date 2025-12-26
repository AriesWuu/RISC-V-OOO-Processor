`timescale 1ns / 1ps

import cpu_pkg::*;

// Load-Store Queue for OOO memory operations
// - Store allocation at dispatch, address/data write at issue
// - Store commit (write to memory) at ROB commit
// - Load forwarding at writeback stage
module LSQ #(
  parameter int SQ_DEPTH     = 8,
  parameter int ROB_ENTRIES  = 16
)(
  input  logic clk,
  input  logic reset,
  input  logic flush_i,
  
  // ROB interface for age comparison and commit
  input  logic [$clog2(ROB_ENTRIES)-1:0] rob_head_i,
  input  logic [$clog2(ROB_ENTRIES)-1:0] rob_tail_cp_i,
  
  // Store allocation (from dispatch, when store enters RS)
  input  logic        sq_alloc_valid_i,
  input  logic [$clog2(ROB_ENTRIES)-1:0] sq_alloc_rob_tag_i,
  output logic        sq_alloc_ready_o,
  output logic [$clog2(SQ_DEPTH)-1:0] sq_alloc_idx_o,
  
  // Store address/data write (when store issues from RS)
  input  logic        sq_write_valid_i,
  input  logic [$clog2(ROB_ENTRIES)-1:0] sq_write_rob_tag_i,
  input  logic [31:0] sq_write_addr_i,
  input  logic [31:0] sq_write_data_i,
  input  logic [3:0]  sq_write_be_i,
  
  // Load forwarding request (at load writeback stage)
  input  logic        ld_fwd_req_i,
  input  logic [$clog2(ROB_ENTRIES)-1:0] ld_fwd_rob_tag_i,
  input  logic [31:0] ld_fwd_addr_i,
  output logic        ld_fwd_valid_o,
  output logic [31:0] ld_fwd_data_o,
  output logic [3:0]  ld_fwd_be_o,
  
  // Store commit (from ROB)
  input  logic        sq_commit_valid_i,
  input  logic [$clog2(ROB_ENTRIES)-1:0] sq_commit_rob_tag_i,
  output logic        sq_commit_ready_o,
  
  // Memory write interface (for committed stores)
  output logic        mem_write_valid_o,
  output logic [31:0] mem_write_addr_o,
  output logic [31:0] mem_write_data_o,
  output logic [3:0]  mem_write_be_o
);

  localparam int ROB_BITS = $clog2(ROB_ENTRIES);
  localparam int SQ_BITS  = $clog2(SQ_DEPTH);

  //===========================================================================
  // Store Queue Entry
  //===========================================================================
  typedef struct packed {
    logic                valid;
    logic                addr_valid;
    logic [ROB_BITS-1:0] rob_tag;
    logic [29:0]         word_addr;
    logic [31:0]         data;
    logic [3:0]          be;
  } sq_entry_t;
  
  sq_entry_t sq [SQ_DEPTH];

  // Map ROB tag -> SQ index to avoid searching the whole SQ on store issue
  logic [SQ_BITS-1:0] rob_to_sq_idx [ROB_ENTRIES];
  logic               rob_to_sq_vld [ROB_ENTRIES];
  
  // SQ pointers (circular buffer)
  logic [SQ_BITS:0] sq_head, sq_tail;
  logic [SQ_BITS:0] sq_count;
  
  assign sq_count = sq_tail - sq_head;
  
  //===========================================================================
  // Helper: Check if rob_tag_a is older than rob_tag_b (wrap-aware)
  //===========================================================================
  function automatic logic is_older(
    input logic [ROB_BITS-1:0] tag_a,
    input logic [ROB_BITS-1:0] tag_b,
    input logic [ROB_BITS-1:0] head
  );
    logic [ROB_BITS-1:0] dist_a, dist_b;
    dist_a = tag_a - head;
    dist_b = tag_b - head;
    return (dist_a < dist_b);
  endfunction
  
  //===========================================================================
  // Helper: Check if entry is speculative
  //===========================================================================
  function automatic logic is_speculative(
    input logic [ROB_BITS-1:0] rob_tag,
    input logic [ROB_BITS-1:0] head,
    input logic [ROB_BITS-1:0] tail_cp
  );
    logic in_valid;
    if (head <= tail_cp)
      in_valid = (rob_tag >= head) && (rob_tag < tail_cp);
    else
      in_valid = (rob_tag >= head) || (rob_tag < tail_cp);
    return !in_valid;
  endfunction

  //===========================================================================
  // Store Allocation
  //===========================================================================
  wire sq_full  = (sq_count == SQ_DEPTH[SQ_BITS:0]);
  wire sq_empty = (sq_count == 0);
  
  assign sq_alloc_ready_o = !sq_full && !flush_i;
  assign sq_alloc_idx_o   = sq_tail[SQ_BITS-1:0];
  
  //===========================================================================
  // Load Forwarding - Find matching older stores
  //===========================================================================
  logic [SQ_DEPTH-1:0] sq_older_mask;
  logic [SQ_DEPTH-1:0] sq_addr_match;
  logic has_forward;
  logic [31:0] fwd_data_merged;
  logic [3:0]  fwd_be_merged;
  
  always_comb begin
    // Initialize
    for (int i = 0; i < SQ_DEPTH; i++) begin
      sq_older_mask[i] = 1'b0;
      sq_addr_match[i] = 1'b0;
    end
    
    has_forward     = 1'b0;
    fwd_data_merged = '0;
    fwd_be_merged   = 4'b0;
    
    if (ld_fwd_req_i) begin
      // Check each SQ entry for matching older stores
      for (int i = 0; i < SQ_DEPTH; i++) begin
        if (sq[i].valid && sq[i].addr_valid) begin
          // Is this store older than the load?
          sq_older_mask[i] = is_older(sq[i].rob_tag, ld_fwd_rob_tag_i, rob_head_i);
          // Does address match?
          sq_addr_match[i] = (sq[i].word_addr == ld_fwd_addr_i[31:2]);
          
          // If older and matching, merge forwarding data
          if (sq_older_mask[i] && sq_addr_match[i]) begin
            has_forward = 1'b1;
            if (sq[i].be[0]) begin fwd_data_merged[7:0]   = sq[i].data[7:0];   fwd_be_merged[0] = 1'b1; end
            if (sq[i].be[1]) begin fwd_data_merged[15:8]  = sq[i].data[15:8];  fwd_be_merged[1] = 1'b1; end
            if (sq[i].be[2]) begin fwd_data_merged[23:16] = sq[i].data[23:16]; fwd_be_merged[2] = 1'b1; end
            if (sq[i].be[3]) begin fwd_data_merged[31:24] = sq[i].data[31:24]; fwd_be_merged[3] = 1'b1; end
          end
        end
      end
    end
  end
  
  assign ld_fwd_valid_o = has_forward;
  assign ld_fwd_data_o  = fwd_data_merged;
  assign ld_fwd_be_o    = fwd_be_merged;
  
  //===========================================================================
  // Store Commit - Write to Memory
  //===========================================================================
  logic commit_match;
  logic [SQ_BITS-1:0] commit_idx;
  
  always_comb begin
    commit_match = 1'b0;
    commit_idx   = sq_head[SQ_BITS-1:0];
    
    if (sq_commit_valid_i && !sq_empty) begin
      if (sq[sq_head[SQ_BITS-1:0]].valid && 
          sq[sq_head[SQ_BITS-1:0]].rob_tag == sq_commit_rob_tag_i &&
          sq[sq_head[SQ_BITS-1:0]].addr_valid) begin
        commit_match = 1'b1;
        commit_idx   = sq_head[SQ_BITS-1:0];
      end
    end
  end
  
  assign sq_commit_ready_o = commit_match;
  assign mem_write_valid_o = commit_match;
  assign mem_write_addr_o  = {sq[commit_idx].word_addr, 2'b00};
  assign mem_write_data_o  = sq[commit_idx].data;
  assign mem_write_be_o    = sq[commit_idx].be;

  //===========================================================================
  // Flush: Count non-speculative entries to update tail
  //===========================================================================
  logic [SQ_BITS:0] non_spec_count;
  always_comb begin
    non_spec_count = '0;
    for (int i = 0; i < SQ_DEPTH; i++) begin
      if (sq[i].valid && !is_speculative(sq[i].rob_tag, rob_head_i, rob_tail_cp_i)) begin
        non_spec_count = non_spec_count + 1'b1;
      end
    end
  end

  //===========================================================================
  // State Update
  //===========================================================================
  always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
      for (int i = 0; i < SQ_DEPTH; i++) begin
        sq[i] <= '0;
      end
      for (int t = 0; t < ROB_ENTRIES; t++) begin
        rob_to_sq_idx[t] <= '0;
        rob_to_sq_vld[t] <= 1'b0;
      end
      sq_head <= '0;
      sq_tail <= '0;
    end else if (flush_i) begin
      // Clear speculative entries
      for (int i = 0; i < SQ_DEPTH; i++) begin
        if (sq[i].valid && is_speculative(sq[i].rob_tag, rob_head_i, rob_tail_cp_i)) begin
          rob_to_sq_vld[sq[i].rob_tag] <= 1'b0;
          sq[i] <= '0;
        end
      end
      // Update tail
      sq_tail <= sq_head + non_spec_count;
    end else begin
      // Allocate new store entry
      if (sq_alloc_valid_i && sq_alloc_ready_o) begin
        sq[sq_tail[SQ_BITS-1:0]].valid      <= 1'b1;
        sq[sq_tail[SQ_BITS-1:0]].addr_valid <= 1'b0;
        sq[sq_tail[SQ_BITS-1:0]].rob_tag    <= sq_alloc_rob_tag_i;
        sq[sq_tail[SQ_BITS-1:0]].word_addr  <= '0;
        sq[sq_tail[SQ_BITS-1:0]].data       <= '0;
        sq[sq_tail[SQ_BITS-1:0]].be         <= '0;

        rob_to_sq_idx[sq_alloc_rob_tag_i] <= sq_tail[SQ_BITS-1:0];
        rob_to_sq_vld[sq_alloc_rob_tag_i] <= 1'b1;
        sq_tail <= sq_tail + 1'b1;
      end
      
      // Write address/data to store entry (when store issues)
      if (sq_write_valid_i) begin
        if (rob_to_sq_vld[sq_write_rob_tag_i]) begin
          logic [SQ_BITS-1:0] widx;
          widx = rob_to_sq_idx[sq_write_rob_tag_i];
          if (sq[widx].valid && (sq[widx].rob_tag == sq_write_rob_tag_i) && !sq[widx].addr_valid) begin
            sq[widx].addr_valid <= 1'b1;
            sq[widx].word_addr  <= sq_write_addr_i[31:2];
            sq[widx].data       <= sq_write_data_i;
            sq[widx].be         <= sq_write_be_i;
          end
        end
      end
      
      // Commit store (dequeue from head)
      if (sq_commit_valid_i && sq_commit_ready_o) begin
        if (sq[sq_head[SQ_BITS-1:0]].valid) begin
          rob_to_sq_vld[sq[sq_head[SQ_BITS-1:0]].rob_tag] <= 1'b0;
        end
        sq[sq_head[SQ_BITS-1:0]] <= '0;
        sq_head <= sq_head + 1'b1;
      end
    end
  end

endmodule
