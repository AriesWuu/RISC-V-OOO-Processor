import cpu_pkg::*;

module decode_module (
  input  logic            clk,
  input  logic            reset,

  // Dual-issue inputs from fetch
  input  fetch_dual_pkt_t fetch_pkt,

  // Dual-issue outputs to rename
  output decode_dual_pkt_t decode_pkt
);

  // ============================================================
  // Decoder 0: First instruction
  // ============================================================
  logic [6:0]  opcode_0;
  logic [2:0]  funct3_0;
  logic [6:0]  funct7_0;
  logic [1:0]  ALUOp_0;
  logic [4:0]  srcReg1_0, srcReg2_0, destReg_0;
  logic [31:0] imm_0;
  logic        hasImm_0;
  logic [1:0]  fu_0;
  logic        branch_0, isJump_0;
  logic        memRead_0, memWrite_0;
  logic        loadByte_0, storeHalf_0;
  logic        regWrite_0, aluSrc_0;
  logic [3:0]  alu_ctrl_0;

  // Field extraction for instruction 0
  assign opcode_0  = fetch_pkt.instr0[6:0];
  assign funct3_0  = fetch_pkt.instr0[14:12];
  assign funct7_0  = fetch_pkt.instr0[31:25];
  assign destReg_0 = fetch_pkt.instr0[11:7];
  assign srcReg1_0 = fetch_pkt.instr0[19:15];
  assign srcReg2_0 = fetch_pkt.instr0[24:20];

  // Immediate decoding for instruction 0
  imm_gen get_imm_0(
    .instr(fetch_pkt.instr0),
    .imm(imm_0),
    .hasImm(hasImm_0)
  );

  // Control unit for instruction 0
  control_unit get_control_0(
    .opcode(opcode_0),
    .funct3(funct3_0),
    .ALUOp(ALUOp_0),
    .fu(fu_0),
    .regWrite(regWrite_0),
    .aluSrc(aluSrc_0),
    .branch(branch_0),
    .isJump(isJump_0),
    .loadByte(loadByte_0),
    .storeHalf(storeHalf_0),
    .memRead(memRead_0),
    .memWrite(memWrite_0),
    .memToReg()  // not used in decode_pkt_t
  );

  // ALU control for instruction 0
  alu_control get_alu_control_0(
    .ALUOp(ALUOp_0),
    .funct3(funct3_0),
    .funct7(funct7_0),
    .alu_ctrl(alu_ctrl_0)
  );

  // ============================================================
  // Decoder 1: Second instruction
  // ============================================================
  logic [6:0]  opcode_1;
  logic [2:0]  funct3_1;
  logic [6:0]  funct7_1;
  logic [1:0]  ALUOp_1;
  logic [4:0]  srcReg1_1, srcReg2_1, destReg_1;
  logic [31:0] imm_1;
  logic        hasImm_1;
  logic [1:0]  fu_1;
  logic        branch_1, isJump_1;
  logic        memRead_1, memWrite_1;
  logic        loadByte_1, storeHalf_1;
  logic        regWrite_1, aluSrc_1;
  logic [3:0]  alu_ctrl_1;

  // Field extraction for instruction 1
  assign opcode_1  = fetch_pkt.instr1[6:0];
  assign funct3_1  = fetch_pkt.instr1[14:12];
  assign funct7_1  = fetch_pkt.instr1[31:25];
  assign destReg_1 = fetch_pkt.instr1[11:7];
  assign srcReg1_1 = fetch_pkt.instr1[19:15];
  assign srcReg2_1 = fetch_pkt.instr1[24:20];

  // Immediate decoding for instruction 1
  imm_gen get_imm_1(
    .instr(fetch_pkt.instr1),
    .imm(imm_1),
    .hasImm(hasImm_1)
  );

  // Control unit for instruction 1
  control_unit get_control_1(
    .opcode(opcode_1),
    .funct3(funct3_1),
    .ALUOp(ALUOp_1),
    .fu(fu_1),
    .regWrite(regWrite_1),
    .aluSrc(aluSrc_1),
    .branch(branch_1),
    .isJump(isJump_1),
    .loadByte(loadByte_1),
    .storeHalf(storeHalf_1),
    .memRead(memRead_1),
    .memWrite(memWrite_1),
    .memToReg()  // not used in decode_pkt_t
  );

  // ALU control for instruction 1
  alu_control get_alu_control_1(
    .ALUOp(ALUOp_1),
    .funct3(funct3_1),
    .funct7(funct7_1),
    .alu_ctrl(alu_ctrl_1)
  );

  // ============================================================
  // Build decode_dual_pkt_t output
  // ============================================================
  always_comb begin
    // Packet 0: First instruction
    decode_pkt.pkt0.pc         = fetch_pkt.pc0;
    decode_pkt.pkt0.pred_hit   = fetch_pkt.pred_hit0;
    decode_pkt.pkt0.pred_taken = fetch_pkt.pred_taken0;
    decode_pkt.pkt0.pred_target= fetch_pkt.pred_target0;
    decode_pkt.pkt0.srcReg1    = srcReg1_0;
    decode_pkt.pkt0.srcReg2    = srcReg2_0;
    decode_pkt.pkt0.destReg    = destReg_0;
    decode_pkt.pkt0.imm        = imm_0;
    decode_pkt.pkt0.fu         = fu_0;
    decode_pkt.pkt0.regWrite   = regWrite_0;
    decode_pkt.pkt0.aluSrc     = aluSrc_0;
    decode_pkt.pkt0.branch     = branch_0;
    decode_pkt.pkt0.isJump     = isJump_0;
    decode_pkt.pkt0.memRead    = memRead_0;
    decode_pkt.pkt0.memWrite   = memWrite_0;
    decode_pkt.pkt0.loadByte   = loadByte_0;
    decode_pkt.pkt0.storeHalf  = storeHalf_0;
    decode_pkt.pkt0.alu_ctrl   = alu_ctrl_0;
    decode_pkt.valid0          = fetch_pkt.valid0;

    // Packet 1: Second instruction
    decode_pkt.pkt1.pc         = fetch_pkt.pc1;
    decode_pkt.pkt1.pred_hit   = fetch_pkt.pred_hit1;
    decode_pkt.pkt1.pred_taken = fetch_pkt.pred_taken1;
    decode_pkt.pkt1.pred_target= fetch_pkt.pred_target1;
    decode_pkt.pkt1.srcReg1    = srcReg1_1;
    decode_pkt.pkt1.srcReg2    = srcReg2_1;
    decode_pkt.pkt1.destReg    = destReg_1;
    decode_pkt.pkt1.imm        = imm_1;
    decode_pkt.pkt1.fu         = fu_1;
    decode_pkt.pkt1.regWrite   = regWrite_1;
    decode_pkt.pkt1.aluSrc     = aluSrc_1;
    decode_pkt.pkt1.branch     = branch_1;
    decode_pkt.pkt1.isJump     = isJump_1;
    decode_pkt.pkt1.memRead    = memRead_1;
    decode_pkt.pkt1.memWrite   = memWrite_1;
    decode_pkt.pkt1.loadByte   = loadByte_1;
    decode_pkt.pkt1.storeHalf  = storeHalf_1;
    decode_pkt.pkt1.alu_ctrl   = alu_ctrl_1;
    decode_pkt.valid1          = fetch_pkt.valid1;
  end

endmodule