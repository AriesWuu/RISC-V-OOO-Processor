module decode_module (
  input  logic        clk,
  input  logic        reset,

  input  logic [31:0] instr,
  output logic [4:0]  srcReg1,
  output logic [4:0]  srcReg2,
  output logic [4:0]  destReg,
  output logic [31:0] imm,
  output logic        hasImm,

  output logic [1:0]  fu,        // 00:ALU, 01:Branch, 10:LSU
  output logic        branch,    // branch (e.g., BNE)
  output logic        memRead,
  output logic        memWrite,
  output logic        memToReg,  // write-back from memory
  output logic        regWrite,
  output logic        aluSrc,    // 1: use immediate as ALU src B

  output logic        isJump,    // JALR
  output logic        loadByte,  // 1: byte, 0: word
  output logic        storeHalf, // 1: half word, 0: word
  output logic [3:0]  alu_ctrl   // ALU operation encoding
);

  logic [6:0]  opcode;
  logic [2:0]  funct3;
  logic [6:0]  funct7;
  logic [1:0]  ALUOp;  // Internal signal for alu_control


  // ---- Field extraction: continuous (combinational) assignments ----
  assign opcode  = instr[6:0];
  assign funct3  = instr[14:12];
  assign funct7  = instr[31:25];
  assign destReg = instr[11:7];
  assign srcReg1 = instr[19:15];
  assign srcReg2 = instr[24:20];

  // ---- Immediate decoding (sign-extended) ----
  imm_gen get_imm(
    .instr(instr),
    .imm(imm),
    .hasImm(hasImm)
  );

  // ---- Combinational control: default NOP, then override per opcode ----
  control_unit get_control(
    .opcode(opcode),
    .funct3(funct3),
    .ALUOp(ALUOp),
    .fu(fu),
    .regWrite(regWrite),
    .aluSrc(aluSrc),
    .branch(branch),
    .isJump(isJump),
    .loadByte(loadByte),
    .storeHalf(storeHalf),
    .memRead(memRead),
    .memWrite(memWrite),
    .memToReg(memToReg)
  );

  // ---- ALU control signal generation ----
  alu_control get_alu_control(
    .ALUOp(ALUOp),
    .funct3(funct3),
    .funct7(funct7),
    .alu_ctrl(alu_ctrl)
  );
endmodule