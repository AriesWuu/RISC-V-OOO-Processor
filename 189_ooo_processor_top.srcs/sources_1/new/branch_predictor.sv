`timescale 1ns / 1ps

module branch_predictor #(
  parameter int ENTRIES = 8
) (
  input  logic        clk,
  input  logic        reset,

  // Fetch-side query
  input  logic [31:0] fetch_pc_i,
  output logic        pred_hit_o,
  output logic        pred_taken_o,
  output logic [31:0] pred_target_o,

  // Update-side (resolve/complete stage)
  input  logic        update_valid_i,
  input  logic [31:0] update_pc_i,
  input  logic        update_taken_i,
  input  logic        update_is_jalr_i,
  input  logic [31:0] update_target_i
);

  localparam int IDX_W = $clog2(ENTRIES);  // Index width
  localparam int TAG_W = 30; // aligned PC tag width (PC[31:2])

  logic [ENTRIES-1:0] valid_r;   // Valid bits for each entry
  logic [TAG_W-1:0]   tag_r    [ENTRIES];  // PC tags (aligned)
  logic [31:0]        target_r [ENTRIES];  // Predicted target addresses
  logic [1:0]         BHT_r    [ENTRIES];  // 2-bit bi-modal history table
  logic               is_jalr_r[ENTRIES];  // 1: JALR (unconditional taken), 0: conditional branch

  logic [IDX_W-1:0]   rr_ptr_r;  // Round-robin pointer for replacement

  // ---------------------------
  // Fetch lookup (combinational)
  // ---------------------------
  logic [ENTRIES-1:0] match_vec;
  logic              hit;
  logic [TAG_W-1:0]   fetch_tag;
  logic              taken_sel;
  logic [31:0]        target_sel;

  assign fetch_tag = fetch_pc_i[31:2];

  // Build match vector (fully-associative compare)
  always_comb begin
    for (int i = 0; i < ENTRIES; i++) begin
      match_vec[i] = valid_r[i] && (tag_r[i] == fetch_tag);
    end
  end

  assign hit = |match_vec;

  always_comb begin
    // One-hot select
    taken_sel  = 1'b0;
    target_sel = 32'b0;
    for (int i = 0; i < ENTRIES; i++) begin
      if (match_vec[i]) begin
        // JALR is always taken (direction doesn't depend on BHT)
        taken_sel  = is_jalr_r[i] ? 1'b1 : BHT_r[i][1];
        target_sel = target_r[i];
      end
    end
  end

  assign pred_hit_o    = hit;
  assign pred_taken_o  = hit && taken_sel;
  assign pred_target_o = hit ? target_sel : 32'b0;

  // ---------------------------
  // BHT next state function
  // ---------------------------
  function automatic [1:0] BHT_next(input [1:0] cur, input logic taken);
    begin
      if (taken) begin
        BHT_next = (cur == 2'b11) ? 2'b11 : (cur + 2'b01);
      end else begin
        BHT_next = (cur == 2'b00) ? 2'b00 : (cur - 2'b01);
      end
    end
  endfunction

  // ---------------------------
  // Update (sequential)
  // ---------------------------
  always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
      valid_r   <= '0;
      rr_ptr_r  <= '0;
      for (int i = 0; i < ENTRIES; i++) begin
        tag_r[i]    <= '0;
        target_r[i] <= 32'b0;
        BHT_r[i]    <= 2'b01; // don't-care when valid=0
        is_jalr_r[i] <= 1'b0;
      end
    end else if (update_valid_i) begin
      logic             upd_hit;
      logic [IDX_W-1:0] upd_idx;
      logic [TAG_W-1:0]  update_tag;

      logic             do_alloc;

      update_tag = update_pc_i[31:2];

      // Scheme 1: only allocate a new BTB entry when the instruction is taken
      // (needs a target) or is a JALR (always needs a target).
      do_alloc = update_is_jalr_i || update_taken_i;

      upd_hit = 1'b0; 
      upd_idx = '0;    
      for (int i = 0; i < ENTRIES; i++) begin
        if (!upd_hit && valid_r[i] && (tag_r[i] == update_tag)) begin
          upd_hit = 1'b1;
          upd_idx = i[IDX_W-1:0];
        end
      end

      if (upd_hit) begin
        target_r[upd_idx]  <= update_target_i;
        // Record instruction type (in case the same PC is reused across tests)
        is_jalr_r[upd_idx] <= update_is_jalr_i;

        // Only conditional branches use BHT direction prediction
        if (!update_is_jalr_i) begin
          BHT_r[upd_idx] <= BHT_next(BHT_r[upd_idx], update_taken_i);
        end
      end else begin
        if (do_alloc) begin
          // Find an invalid entry first; otherwise choose a victim.
          logic             found_free;
          logic [IDX_W-1:0] free_idx;

          // Scheme 2 (replacement): when full, prefer evicting entries that are
          // not JALR and currently biased not-taken (lower value / likely cold).
          logic             victim_found;
          logic [IDX_W-1:0] victim_idx;
          logic [IDX_W-1:0] alloc_idx;

          found_free = 1'b0;
          free_idx   = '0;
          for (int i = 0; i < ENTRIES; i++) begin
            if (!found_free && !valid_r[i]) begin
              found_free = 1'b1;
              free_idx   = i[IDX_W-1:0];
            end
          end

          victim_found = 1'b0;
          victim_idx   = rr_ptr_r;
          for (int k = 0; k < ENTRIES; k++) begin
            int idx;
            idx = (int'(rr_ptr_r) + k);
            if (idx >= ENTRIES) idx = idx - ENTRIES;

            if (!victim_found && valid_r[idx] && !is_jalr_r[idx] && !BHT_r[idx][1]) begin
              victim_found = 1'b1;
              // NOTE: avoid bit-slicing an int (Vivado parser); truncate by assignment.
              victim_idx   = idx;
            end
          end
          alloc_idx = found_free ? free_idx : (victim_found ? victim_idx : rr_ptr_r);

          valid_r[alloc_idx]   <= 1'b1;
          tag_r[alloc_idx]     <= update_tag;
          target_r[alloc_idx]  <= update_target_i;
          is_jalr_r[alloc_idx] <= update_is_jalr_i;
          // BHT init based on first observed outcome (strong taken / strong not-taken)
          BHT_r[alloc_idx]     <= update_taken_i ? 2'b11 : 2'b00;

          // Advance replacement pointer only when we actually replaced an entry.
          if (!found_free) begin
            rr_ptr_r <= alloc_idx + 1'b1;
          end
        end
      end
    end
  end

endmodule
