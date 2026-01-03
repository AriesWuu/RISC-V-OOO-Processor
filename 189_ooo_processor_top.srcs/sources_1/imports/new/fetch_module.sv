import cpu_pkg::*;

//`include "../rtl/i_cache.sv"
//`include "../rtl/pc_counter.sv"
module fetch_module #(
  parameter int    WORDS      = 512,
  parameter string MEMFILE    = ""
)(
  input  logic            clk,
  input  logic            reset,
  input  logic            pc_src,      // PC source: 0 - sequential, 1 - branch/jump
  input  logic [31:0]     pc_branch,   // Branch/jump target address
  input  logic            pred_taken_0_i,
  input  logic [31:0]     pred_target_0_i,
  input  logic            pred_taken_1_i,
  input  logic [31:0]     pred_target_1_i,
  // handshake signals
  input  logic            ready_out,   // Indicates if the downstream can accept data
  output logic            valid_in,    // Indicates if the input into the skid buffer is valid
  // outputs
  output fetch_dual_pkt_t fetch_pkt
);
  logic        stall_F;
  logic        program_end_0, program_end_1;  // Detect end of program
  logic [31:0] pc_0, pc_1;
  logic [31:0] instr_0, instr_1;
  logic        fetch_dual;

  // Determine if we can dual-fetch
  // Dual-fetch when: downstream ready AND first instruction not end-of-program
  assign fetch_dual = ready_out && ~program_end_0;

  assign stall_F = ~ready_out | program_end_0;  // Stall if downstream not ready OR program ended

  // Instantiate the program counter
  pc_counter pc_counter_inst (
    .clk(clk),
    .reset(reset),
    .pc_src(pc_src),
    .stall_F(stall_F),
    .pc_branch(pc_branch),
    .pred_taken_0(pred_taken_0_i),
    .pred_target_0(pred_target_0_i),
    .pred_taken_1(pred_taken_1_i),
    .pred_target_1(pred_target_1_i),
    .fetch_dual(fetch_dual),
    .pc_0(pc_0),
    .pc_1(pc_1)
  );

  // Instantiate the instruction cache (dual-port)
  i_cache #(
    .WORDS(WORDS),
    .MEMFILE(MEMFILE)
  ) i_cache_inst (
    .addr0  (pc_0),
    .addr1  (pc_1),
    .instr0 (instr_0),
    .instr1 (instr_1)
  );

  // Detect end of program: instruction is all zeros
  assign program_end_0 = (instr_0 == 32'h00000000);
  assign program_end_1 = (instr_1 == 32'h00000000);

  // Build fetch_dual_pkt_t output
  always_comb begin
    fetch_pkt.pc0         = pc_0;
    fetch_pkt.instr0      = instr_0;
    fetch_pkt.valid0      = ~program_end_0;
    fetch_pkt.pred_hit0   = 1'b0;  // BTB not implemented yet
    fetch_pkt.pred_taken0 = pred_taken_0_i;
    fetch_pkt.pred_target0= pred_target_0_i;

    fetch_pkt.pc1         = pc_1;
    fetch_pkt.instr1      = instr_1;
    fetch_pkt.valid1      = fetch_dual && ~program_end_1;  // Valid only if dual-fetch AND not end
    fetch_pkt.pred_hit1   = 1'b0;  // BTB not implemented yet
    fetch_pkt.pred_taken1 = pred_taken_1_i;
    fetch_pkt.pred_target1= pred_target_1_i;
  end

  // Output assignments - valid if at least first instruction is valid
  assign valid_in = fetch_pkt.valid0;

endmodule