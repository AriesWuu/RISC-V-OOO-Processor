//`include "../rtl/i_cache.sv"
//`include "../rtl/pc_counter.sv"
module fetch_module #(
  parameter int    WORDS      = 512,
  parameter string MEMFILE    = ""
)(
  input  logic        clk,
  input  logic        reset,
  input  logic        pc_src,      // PC source: 0 - sequential, 1 - branch/jump
  input  logic [31:0] pc_branch,   // Branch/jump target address
  input  logic        pred_taken_i,
  input  logic [31:0] pred_target_i,
  // handshake signals
  input  logic        ready_out,     // Indicates if the downstream can accept data
  output logic        valid_in,     // Indicates if the input into the skid buffer is valid
  // outputs
  output logic [31:0] pc,
  output logic [31:0] instr    
);
  logic        stall_F;
  logic        program_end;  // Detect end of program (all-zero instruction)
  
  assign stall_F = ~ready_out | program_end;  // Stall if downstream not ready OR program ended
  
  // Instantiate the program counter
  pc_counter pc_counter_inst (
    .clk(clk),
    .reset(reset),
    .pc_src(pc_src),
    .stall_F(stall_F),
    .pc_branch(pc_branch),
    .pred_taken_i(pred_taken_i),
    .pred_target_i(pred_target_i),
    .pc(pc)
  );

  // Instantiate the instruction cache
  i_cache #(
    .WORDS(WORDS),
    .MEMFILE(MEMFILE)
  ) i_cache_inst (
    .addr  (pc),
    .instr (instr)
  );

  // Detect end of program: instruction is all zeros
  assign program_end = (instr == 32'h00000000);

  // Output assignments - not valid if instruction is all zeros (end of program)
  assign valid_in = ~program_end;

endmodule