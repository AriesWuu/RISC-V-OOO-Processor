module rename_module #(
  parameter int ARCH_REGS   = 32,
  parameter int PHYS_REGS   = 96,
  parameter int ROB_ENTRIES = 16
)(
  input  logic         clk,
  input  logic         reset,
  // input from top
  input  logic         ready_from_dispatch,
  input  logic         valid_from_decode,
  input  logic [4:0]   srcReg1_arch,
  input  logic [4:0]   srcReg2_arch,
  input  logic [4:0]   destReg_arch,
  input  logic         regWrite_rename,
  input  logic         branch_rename,

  // Control signals from decode for op packing
  input  logic [1:0]   fu_i,           // 00:ALU, 01:Branch, 10:LSU
  input  logic [3:0]   alu_ctrl_i,     // ALU operation encoding
  input  logic         aluSrc_i,       // 1: use immediate as ALU src B
  input  logic         isJump_i,       // JALR
  input  logic         memRead_i,      // load operation
  input  logic         memWrite_i,     // store operation
  input  logic         loadByte_i,     // 1: LBU, 0: LW
  input  logic         storeHalf_i,    // 1: SH, 0: SW
  input  logic [31:0]  imm_i,          // immediate value
  input  logic [31:0]  pc_i,           // PC for branch target calculation
  input  logic         pred_hit_i,
  input  logic         pred_taken_i,
  input  logic [31:0]  pred_target_i,

  // branch mispredict signal and recovery tag
  input  logic         branch_miss_rename,
  input  logic [$clog2(ROB_ENTRIES)-1:0] recover_tag_i,  // ROB tag of mispredicting branch
  // retire signal
  input  logic         retire_enable, 
  input  logic [6:0]   retired_destReg_phys,
  // output to next stage
  output logic         valid_to_dispatch,
  output logic         ready_to_decode,
  output logic [6:0]   srcReg1_phys,
  output logic [6:0]   srcReg2_phys,
  output logic [6:0]   destReg_phys,
  output logic [6:0]   oldDest_phys,
  output logic [$clog2(ROB_ENTRIES)-1:0] rob_tag,

  // Packed micro_op and control signals to dispatch
  output logic [6:0]   micro_op_o,     // Packed micro-operation code (not RISC-V opcode)
  output logic [1:0]   fu_o,           // Function unit (pass-through)
  output logic         is_branch_o,    // Is branch instruction
  output logic         writes_rd_o,    // Writes to register file
  output logic [31:0]  imm_o,          // Immediate value (pass-through)
  output logic [31:0]  pc_o,           // PC (pass-through)
  output logic         pred_hit_o,
  output logic         pred_taken_o,
  output logic [31:0]  pred_target_o
);
  // Internal signals
  logic take_branch;
  logic write_enable;
  logic update_rob_tag;
  
  assign take_branch      = valid_from_decode && (branch_rename || isJump_i);
  assign write_enable     = valid_from_decode && regWrite_rename && (destReg_arch != 5'd0);
  assign update_rob_tag   = valid_from_decode && ready_from_dispatch;
  
  // Recovery uses the next tag after the mispredicting branch
  // This is the checkpoint that was saved when that branch was allocated
  logic [$clog2(ROB_ENTRIES)-1:0] recovery_checkpoint_tag;
  assign recovery_checkpoint_tag = recover_tag_i;  // The branch's own tag points to its checkpoint
  
  // Instantiate Map Table
  map_table #(
    .ARCH_REGS   (ARCH_REGS),
    .ROB_ENTRIES (ROB_ENTRIES)
  ) u_map_table (
    .clk              (clk),
    .reset            (reset),
    .rs1_arch         (srcReg1_arch),
    .rs2_arch         (srcReg2_arch),
    .rd_arch          (destReg_arch),
    .wr_en_dst        (write_enable),
    .branch_checkpoint(take_branch),
    .checkpoint_tag   (rob_tag),              // Save checkpoint at current ROB tag
    .branch_recover   (branch_miss_rename),
    .recover_tag      (recovery_checkpoint_tag),  // Restore from mispredicting branch's tag
    .rd_prf           (destReg_phys),
    .rs1_prf          (srcReg1_phys),
    .rs2_prf          (srcReg2_phys),
    .rd_old_prf       (oldDest_phys)
  );

  // ---- Free List 实例 ----
  free_list #(
    .PHYS_REGS   (PHYS_REGS),
    .ROB_ENTRIES (ROB_ENTRIES)
  ) u_free_list (
    .clk               (clk),
    .reset             (reset),
    .retire_en         (retire_enable),
    .allocate_en       (write_enable),
    .retired_preg      (retired_destReg_phys),
    .branch_checkpoint (take_branch),
    .checkpoint_tag    (rob_tag),             // Save checkpoint at current ROB tag
    .branch_recover    (branch_miss_rename),
    .recover_tag       (recovery_checkpoint_tag),  // Restore from mispredicting branch's tag
    .alloc_rdy         (ready_to_decode),
    .new_preg          (destReg_phys)
  );

  // Instantiate ROB Tag
  rob_tag #(
    .ROB_ENTRIES (ROB_ENTRIES)
  ) u_rob_tag (
    .clk               (clk),
    .reset             (reset),
    .inc_en            (update_rob_tag),
    .rob_tag           (rob_tag),
    .branch_checkpoint (take_branch),
    .checkpoint_tag    (rob_tag),             // Save checkpoint at current ROB tag
    .branch_recover    (branch_miss_rename),
    .recover_tag       (recovery_checkpoint_tag)   // Restore from mispredicting branch's tag
  );
  
  // Handshake signals
  assign valid_to_dispatch = valid_from_decode && ready_to_decode;

  // =====================
  // Pack micro_op field based on function unit (fu)
  // =====================
  // micro_op[6:0] encoding by fu:
  //   fu=00 (ALU):    {2'b00, aluSrc, alu_ctrl[3:0]}
  //   fu=01 (Branch): {5'b00000, isJump, branch}
  //   fu=10 (LSU):    {3'b000, storeHalf, loadByte, memWrite, memRead}
  always_comb begin
    case (fu_i)
      2'b00: micro_op_o = {2'b00, aluSrc_i, alu_ctrl_i};              // ALU
      2'b01: micro_op_o = {5'b00000, isJump_i, branch_rename};        // Branch
      2'b10: micro_op_o = {3'b000, storeHalf_i, loadByte_i, memWrite_i, memRead_i}; // LSU
      default: micro_op_o = 7'b0;
    endcase
  end

  // Pass-through signals
  assign fu_o        = fu_i;
  assign is_branch_o = branch_rename || isJump_i;
  assign writes_rd_o = regWrite_rename;
  assign imm_o       = imm_i;
  assign pc_o        = pc_i;
  assign pred_hit_o    = pred_hit_i;
  assign pred_taken_o  = pred_taken_i;
  assign pred_target_o = pred_target_i;

endmodule