import cpu_pkg::*;

module rename_module #(
  parameter int ARCH_REGS   = 32,
  parameter int PHYS_REGS   = 96,
  parameter int ROB_ENTRIES = 16
)(
  input  logic              clk,
  input  logic              reset,

  // Dual-issue input from decode stage
  input  logic              ready_from_dispatch,
  input  decode_dual_pkt_t  decode_pkt_i,
  input  logic              valid_from_decode,

  // Branch mispredict signal and recovery tag
  input  logic              branch_miss_rename,
  input  logic [$clog2(ROB_ENTRIES)-1:0] recover_tag_i,

  // Retire signals (dual retire support)
  input  logic              retire_enable_0,
  input  logic [6:0]        retired_destReg_phys_0,
  input  logic              retire_enable_1,
  input  logic [6:0]        retired_destReg_phys_1,

  // Dual-issue output to dispatch stage
  output logic              valid_to_dispatch,
  output logic              ready_to_decode,
  output rename_dual_pkt_t  rename_pkt_o
);
  // ============================================================
  // Dual-issue control signals
  // ============================================================
  localparam int PRF_BITS = $clog2(PHYS_REGS);
  localparam int ROB_BITS = $clog2(ROB_ENTRIES);

  // Instruction 0 signals
  logic        take_branch_0, write_enable_0;
  logic [6:0]  srcReg1_phys_0, srcReg2_phys_0;
  logic [6:0]  destReg_phys_0, oldDest_phys_0;
  logic [ROB_BITS-1:0] rob_tag_0;
  logic [6:0]  micro_op_0;

  // Instruction 1 signals
  logic        take_branch_1, write_enable_1;
  logic [6:0]  srcReg1_phys_1, srcReg2_phys_1;
  logic [6:0]  destReg_phys_1, oldDest_phys_1;
  logic [ROB_BITS-1:0] rob_tag_1;
  logic [6:0]  micro_op_1;

  // Dual-issue enables
  logic        update_rob_tag_0, update_rob_tag_1;
  logic        alloc_rdy_0, alloc_rdy_1;

  // Branch/write enables for each instruction
  assign take_branch_0  = valid_from_decode && decode_pkt_i.valid0 && (decode_pkt_i.pkt0.branch || decode_pkt_i.pkt0.isJump);
  assign write_enable_0 = valid_from_decode && decode_pkt_i.valid0 && decode_pkt_i.pkt0.regWrite && (decode_pkt_i.pkt0.destReg != 5'd0);

  assign take_branch_1  = valid_from_decode && decode_pkt_i.valid1 && (decode_pkt_i.pkt1.branch || decode_pkt_i.pkt1.isJump);
  assign write_enable_1 = valid_from_decode && decode_pkt_i.valid1 && decode_pkt_i.pkt1.regWrite && (decode_pkt_i.pkt1.destReg != 5'd0);

  // ROB tag increment enables (when instruction enters rename and dispatch is ready)
  assign update_rob_tag_0 = valid_from_decode && decode_pkt_i.valid0 && ready_from_dispatch;
  assign update_rob_tag_1 = valid_from_decode && decode_pkt_i.valid1 && ready_from_dispatch;

  // Recovery checkpoint tag
  logic [ROB_BITS-1:0] recovery_checkpoint_tag;
  assign recovery_checkpoint_tag = recover_tag_i;

  // Branch checkpoint logic: save checkpoint on FIRST branch encountered
  logic        branch_checkpoint;
  logic [ROB_BITS-1:0] checkpoint_tag;
  always_comb begin
    if (take_branch_0) begin
      // First instruction is branch - use its tag
      branch_checkpoint = 1'b1;
      checkpoint_tag    = rob_tag_0;
    end else if (take_branch_1) begin
      // Second instruction is branch - use its tag
      branch_checkpoint = 1'b1;
      checkpoint_tag    = rob_tag_1;
    end else begin
      branch_checkpoint = 1'b0;
      checkpoint_tag    = rob_tag_0;  // Don't care
    end
  end

  // ============================================================
  // Instantiate Map Table (4-read, 2-write)
  // ============================================================
  map_table #(
    .ARCH_REGS   (ARCH_REGS),
    .ROB_ENTRIES (ROB_ENTRIES)
  ) u_map_table (
    .clk              (clk),
    .reset            (reset),
    // Dual-issue read ports
    .rs1_arch_0       (decode_pkt_i.pkt0.srcReg1),
    .rs2_arch_0       (decode_pkt_i.pkt0.srcReg2),
    .rd_arch_0        (decode_pkt_i.pkt0.destReg),
    .rs1_arch_1       (decode_pkt_i.pkt1.srcReg1),
    .rs2_arch_1       (decode_pkt_i.pkt1.srcReg2),
    .rd_arch_1        (decode_pkt_i.pkt1.destReg),
    // Dual-issue write ports
    .wr_en_0          (write_enable_0),
    .wr_en_1          (write_enable_1),
    .rd_prf_0         (destReg_phys_0),
    .rd_prf_1         (destReg_phys_1),
    // Outputs with RAW/WAW detection
    .rs1_prf_0        (srcReg1_phys_0),
    .rs2_prf_0        (srcReg2_phys_0),
    .rd_old_prf_0     (oldDest_phys_0),
    .rs1_prf_1        (srcReg1_phys_1),
    .rs2_prf_1        (srcReg2_phys_1),
    .rd_old_prf_1     (oldDest_phys_1),
    // Branch checkpoint/recovery
    .branch_checkpoint(branch_checkpoint),
    .checkpoint_tag   (checkpoint_tag),
    .branch_recover   (branch_miss_rename),
    .recover_tag      (recovery_checkpoint_tag)
  );

  // ============================================================
  // Instantiate Free List (dual allocation/retire)
  // ============================================================
  free_list #(
    .ARCH_REGS   (ARCH_REGS),
    .PHYS_REGS   (PHYS_REGS),
    .ROB_ENTRIES (ROB_ENTRIES)
  ) u_free_list (
    .clk               (clk),
    .reset             (reset),
    // Dual retire
    .retire_en_0       (retire_enable_0),
    .retired_preg_0    (retired_destReg_phys_0),
    .retire_en_1       (retire_enable_1),
    .retired_preg_1    (retired_destReg_phys_1),
    // Dual allocate
    .allocate_en_0     (write_enable_0),
    .allocate_en_1     (write_enable_1),
    .alloc_rdy_0       (alloc_rdy_0),
    .alloc_rdy_1       (alloc_rdy_1),
    .new_preg_0        (destReg_phys_0),
    .new_preg_1        (destReg_phys_1),
    // Branch checkpoint/recovery
    .branch_checkpoint (branch_checkpoint),
    .checkpoint_tag    (checkpoint_tag),
    .branch_recover    (branch_miss_rename),
    .recover_tag       (recovery_checkpoint_tag)
  );

  // ============================================================
  // Instantiate ROB Tag (dual tag allocation)
  // ============================================================
  rob_tag #(
    .ROB_ENTRIES (ROB_ENTRIES)
  ) u_rob_tag (
    .clk               (clk),
    .reset             (reset),
    // Dual increment
    .inc_en_0          (update_rob_tag_0),
    .inc_en_1          (update_rob_tag_1),
    .rob_tag_0         (rob_tag_0),
    .rob_tag_1         (rob_tag_1),
    // Branch checkpoint/recovery
    .branch_checkpoint (branch_checkpoint),
    .checkpoint_tag    (checkpoint_tag),
    .branch_recover    (branch_miss_rename),
    .recover_tag       (recovery_checkpoint_tag)
  );

  // ============================================================
  // Ready/Valid handshake logic
  // ============================================================
  // Ready to decode if:
  // - We can allocate at least 1 physical register (for instr0)
  // - If instr1 is also valid, we need 2 physical registers
  always_comb begin
    if (decode_pkt_i.valid1 && write_enable_1) begin
      // Dual-issue with dual-write: need 2 free registers
      ready_to_decode = alloc_rdy_1;
    end else begin
      // Single-issue OR dual-issue with only first writing: need 1 free register
      ready_to_decode = alloc_rdy_0;
    end
  end

  // Valid to dispatch if decode is valid and we're ready
  assign valid_to_dispatch = valid_from_decode && ready_to_decode;

  // ============================================================
  // Pack micro_op field for each instruction
  // ============================================================
  // micro_op[6:0] encoding by fu:
  //   fu=00 (ALU):    {2'b00, aluSrc, alu_ctrl[3:0]}
  //   fu=01 (Branch): {5'b00000, isJump, branch}
  //   fu=10 (LSU):    {3'b000, storeHalf, loadByte, memWrite, memRead}

  // Instruction 0
  always_comb begin
    case (decode_pkt_i.pkt0.fu)
      2'b00: micro_op_0 = {2'b00, decode_pkt_i.pkt0.aluSrc, decode_pkt_i.pkt0.alu_ctrl};
      2'b01: micro_op_0 = {5'b00000, decode_pkt_i.pkt0.isJump, decode_pkt_i.pkt0.branch};
      2'b10: micro_op_0 = {3'b000, decode_pkt_i.pkt0.storeHalf, decode_pkt_i.pkt0.loadByte,
                           decode_pkt_i.pkt0.memWrite, decode_pkt_i.pkt0.memRead};
      default: micro_op_0 = 7'b0;
    endcase
  end

  // Instruction 1
  always_comb begin
    case (decode_pkt_i.pkt1.fu)
      2'b00: micro_op_1 = {2'b00, decode_pkt_i.pkt1.aluSrc, decode_pkt_i.pkt1.alu_ctrl};
      2'b01: micro_op_1 = {5'b00000, decode_pkt_i.pkt1.isJump, decode_pkt_i.pkt1.branch};
      2'b10: micro_op_1 = {3'b000, decode_pkt_i.pkt1.storeHalf, decode_pkt_i.pkt1.loadByte,
                           decode_pkt_i.pkt1.memWrite, decode_pkt_i.pkt1.memRead};
      default: micro_op_1 = 7'b0;
    endcase
  end

  // ============================================================
  // Build rename_dual_pkt_t output
  // ============================================================
  always_comb begin
    // Packet 0: First instruction
    rename_pkt_o.pkt0.micro_op    = micro_op_0;
    rename_pkt_o.pkt0.dst_prf_new = destReg_phys_0;
    rename_pkt_o.pkt0.dst_prf_old = oldDest_phys_0;
    rename_pkt_o.pkt0.src0_prf    = srcReg1_phys_0;
    rename_pkt_o.pkt0.src1_prf    = srcReg2_phys_0;
    rename_pkt_o.pkt0.imm         = decode_pkt_i.pkt0.imm;
    rename_pkt_o.pkt0.fu          = decode_pkt_i.pkt0.fu;
    rename_pkt_o.pkt0.is_branch   = decode_pkt_i.pkt0.branch || decode_pkt_i.pkt0.isJump;
    rename_pkt_o.pkt0.writes_rd   = decode_pkt_i.pkt0.regWrite;
    rename_pkt_o.pkt0.rob_tag     = rob_tag_0;
    rename_pkt_o.pkt0.pc          = decode_pkt_i.pkt0.pc;
    rename_pkt_o.pkt0.pred_hit    = decode_pkt_i.pkt0.pred_hit;
    rename_pkt_o.pkt0.pred_taken  = decode_pkt_i.pkt0.pred_taken;
    rename_pkt_o.pkt0.pred_target = decode_pkt_i.pkt0.pred_target;
    rename_pkt_o.valid0           = decode_pkt_i.valid0;

    // Packet 1: Second instruction
    rename_pkt_o.pkt1.micro_op    = micro_op_1;
    rename_pkt_o.pkt1.dst_prf_new = destReg_phys_1;
    rename_pkt_o.pkt1.dst_prf_old = oldDest_phys_1;
    rename_pkt_o.pkt1.src0_prf    = srcReg1_phys_1;
    rename_pkt_o.pkt1.src1_prf    = srcReg2_phys_1;
    rename_pkt_o.pkt1.imm         = decode_pkt_i.pkt1.imm;
    rename_pkt_o.pkt1.fu          = decode_pkt_i.pkt1.fu;
    rename_pkt_o.pkt1.is_branch   = decode_pkt_i.pkt1.branch || decode_pkt_i.pkt1.isJump;
    rename_pkt_o.pkt1.writes_rd   = decode_pkt_i.pkt1.regWrite;
    rename_pkt_o.pkt1.rob_tag     = rob_tag_1;
    rename_pkt_o.pkt1.pc          = decode_pkt_i.pkt1.pc;
    rename_pkt_o.pkt1.pred_hit    = decode_pkt_i.pkt1.pred_hit;
    rename_pkt_o.pkt1.pred_taken  = decode_pkt_i.pkt1.pred_taken;
    rename_pkt_o.pkt1.pred_target = decode_pkt_i.pkt1.pred_target;
    rename_pkt_o.valid1           = decode_pkt_i.valid1;
  end

endmodule