module pc_counter (
  input  logic        clk,
  input  logic        reset,
  input  logic        pc_src,      // PC source: 0 - sequential, 1 - branch/recovery
  input  logic        stall_F,     // Stall the fetch stage
  input  logic [31:0] pc_branch,   // Branch/jump target address
  input  logic        pred_taken_0, // BTB prediction for first instruction
  input  logic [31:0] pred_target_0,
  input  logic        pred_taken_1, // BTB prediction for second instruction
  input  logic [31:0] pred_target_1,
  input  logic        fetch_dual,   // Indicates dual-fetch is occurring
  output logic [31:0] pc_0,         // PC for first instruction
  output logic [31:0] pc_1          // PC for second instruction (PC+4)
);
  logic [31:0] pc_current, pc_next;

  // Dual PC outputs
  assign pc_0 = pc_current;
  assign pc_1 = pc_current + 32'd4;

  always_ff @(posedge clk) begin
    if (reset) begin
      pc_current <= 32'h0000_0000;
    end else if (pc_src) begin
      // On branch/recovery, always update PC regardless of stall
      pc_current <= pc_branch;
    end else if (!stall_F) begin
      pc_current <= pc_next;
    end
  end

  // Next PC calculation for dual-issue:
  // Priority: pred_taken_0 > pred_taken_1 > dual-fetch (+8) > single-fetch (+4)
  always_comb begin
    if (pred_taken_0) begin
      // First instruction predicted taken - jump to its target
      pc_next = pred_target_0;
    end else if (pred_taken_1 && fetch_dual) begin
      // Second instruction predicted taken (only valid in dual-fetch)
      pc_next = pred_target_1;
    end else if (fetch_dual) begin
      // Dual-fetch sequential: advance by 8 bytes
      pc_next = pc_current + 32'd8;
    end else begin
      // Single-fetch sequential: advance by 4 bytes
      pc_next = pc_current + 32'd4;
    end
  end

endmodule