module control_unit (
  input  logic [6:0] opcode,
  input  logic [2:0] funct3,    

  output logic [1:0]  ALUOp,     // 00: add, 01: sub, 10: R-type, I-type, 11: LUI-type
  output logic [1:0]  fu,        // 00:ALU, 01:Branch, 10:LSU
  output logic        regWrite,
  output logic        aluSrc,    // 1: use immediate as ALU src B
  output logic        branch,    // branch (e.g., BNE)
  output logic        isJump,    // JALR
  output logic        loadByte,  // 1: byte, 0: word
  output logic        storeHalf, // 1: half word, 0: word
  output logic        memRead,
  output logic        memWrite,
  output logic        memToReg   // write-back from memory
);

  // ---- Primary opcodes ----
  localparam logic [6:0] OP      = 7'b0110011; // R-type
  localparam logic [6:0] OP_IMM  = 7'b0010011; // I-type (ALU imm)
  localparam logic [6:0] LOAD    = 7'b0000011; // loads
  localparam logic [6:0] STORE   = 7'b0100011; // stores
  localparam logic [6:0] BRANCH  = 7'b1100011; // branches
  localparam logic [6:0] JALR_OP = 7'b1100111; // JALR
  localparam logic [6:0] LUI_OP  = 7'b0110111; // LUI
  // localparam logic [6:0] JAL_OP  = 7'b1101111;

  always_comb begin
    // Default NOP-like values to avoid latches
    fu        = 2'b00;  // Default to ALU
    ALUOp     = 2'b00;
    regWrite  = 1'b0;
    aluSrc    = 1'b0;
    branch    = 1'b0;
    isJump    = 1'b0;
    loadByte  = 1'b0;
    storeHalf = 1'b0;
    memRead   = 1'b0;
    memWrite  = 1'b0;
    memToReg  = 1'b0;

    case (opcode)
      OP: begin
        // R-type ALU ops (e.g., AND, SUB, SRA) resolved by funct3/funct7
        fu       = 2'b00;      // ALU
        ALUOp    = 2'b10;
        regWrite = 1'b1;
        aluSrc   = 1'b0;     // use rs2
      end
      OP_IMM: begin
        // I-type ALU ops (e.g., ADDI, ORI, SLTIU, SRAI)
        fu       = 2'b00;      // ALU
        ALUOp    = 2'b10;
        regWrite = 1'b1;
        aluSrc   = 1'b1;     // use imm_i
      end
      LOAD: begin
        // Address: rs1 + imm_i; write back loaded data
        fu       = 2'b10;      // LSU
        ALUOp    = 2'b00;    // address add
        regWrite = 1'b1;
        aluSrc   = 1'b1;
        memRead  = 1'b1;
        memToReg = 1'b1;
        case (funct3)
          3'b010: loadByte = 1'b0; // LW
          3'b100: loadByte = 1'b1; // LBU
          default: loadByte = 1'b0; // LW
        endcase
      end
      STORE: begin
        // Address: rs1 + imm_s; no write-back
        fu       = 2'b10;      // LSU
        ALUOp    = 2'b00;    // address add
        regWrite = 1'b0;
        aluSrc   = 1'b1;
        memWrite = 1'b1;
        case (funct3)
          3'b010: storeHalf = 1'b0; // SW
          3'b001: storeHalf = 1'b1; // SH
          default: storeHalf = 1'b0; // SW
        endcase
      end
      BRANCH: begin
        // Branch (e.g., BNE). Compare rs1 vs rs2; immediate is imm_b
        fu       = 2'b01;      // Branch Unit
        ALUOp    = 2'b01;    // typically used as compare/sub in EX
        branch   = 1'b1;
        aluSrc   = 1'b0;
      end
      JALR_OP: begin
        // JALR: rd <- PC+4; branch target = rs1 + imm_i
        fu       = 2'b01;      // Branch Unit
        ALUOp    = 2'b00;    // address add
        isJump   = 1'b1;
        regWrite = 1'b1;     // write PC+4 in WB stage
        aluSrc   = 1'b1;     // address calc uses imm_i
      end
      LUI_OP: begin
        // LUI: rd <- imm_u (handled by ALU pass-through in EX)
        fu       = 2'b00;      // ALU
        ALUOp    = 2'b11;    // LUI-type operation
        regWrite = 1'b1;
        aluSrc   = 1'b1;
      end
      default: ; // Keep defaults (treated as NOP/illegal handled elsewhere)
    endcase
  end
endmodule