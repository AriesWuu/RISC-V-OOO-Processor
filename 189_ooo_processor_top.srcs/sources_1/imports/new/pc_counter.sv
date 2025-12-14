module pc_counter (
  input  logic        clk,
  input  logic        reset,
  input  logic        pc_src,      // PC source: 0 - sequential, 1 - branch/recovery
  input  logic        stall_F,    // Stall the fetch stage
  input  logic [31:0] pc_branch,   // Branch/jump target address
  input  logic        pred_taken_i,
  input  logic [31:0] pred_target_i,
  output logic [31:0] pc
);
  logic [31:0] pc_current, pc_next;
  
  assign pc = pc_current;
  
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
  
  always_comb begin
    pc_next = pred_taken_i ? pred_target_i : (pc_current + 32'd4);
  end
  
endmodule