module imm_gen (
  input  logic [31:0] instr,
  output logic [31:0] imm,
  output logic        hasImm
);

  // ---- Immediate decoding (sign-extended) ----
  logic [31:0] imm_i, imm_s, imm_u, imm_b /*, imm_j*/;
  assign imm_i = {{20{instr[31]}}, instr[31:20]};
  assign imm_s = {{20{instr[31]}}, instr[31:25], instr[11:7]};
  assign imm_u = {instr[31:12], 12'b0};
  assign imm_b = {{19{instr[31]}}, instr[31], instr[7],
                  instr[30:25], instr[11:8], 1'b0};
  // logic [31:0] imm_j = {{11{instr[31]}}, instr[31], instr[19:12],
  //                       instr[20], instr[30:21], 1'b0};

  // ---- Primary opcodes ----
  localparam logic [6:0] OP      = 7'b0110011; // R-type
  localparam logic [6:0] OP_IMM  = 7'b0010011; // I-type (ALU imm)
  localparam logic [6:0] LOAD    = 7'b0000011; // loads
  localparam logic [6:0] STORE   = 7'b0100011; // stores
  localparam logic [6:0] BRANCH  = 7'b1100011; // branches
  localparam logic [6:0] JALR_OP = 7'b1100111; // JALR
  localparam logic [6:0] LUI_OP  = 7'b0110111; // LUI
  // localparam logic [6:0] JAL_OP  = 7'b1101111;

  // ---- Combinational control: default NOP, then override per opcode ----
  always_comb begin
    // Default NOP-like values to avoid latches
    imm    = '0;
    hasImm = 1'b0;

    unique case (instr[6:0])
      OP_IMM, LOAD, JALR_OP: begin
        imm    = imm_i;
        hasImm = 1'b1;
      end
      STORE: begin
        imm    = imm_s;
        hasImm = 1'b1;
      end
      BRANCH: begin
        imm    = imm_b;
        hasImm = 1'b1;
      end
      LUI_OP: begin
        imm    = imm_u;
        hasImm = 1'b1;
      end
      // JAL_OP: begin
      //   imm    = imm_jal;
      //   hasImm = 1'b1;
      // end
      default: begin
        imm    = '0;
        hasImm = 1'b0;
      end
    endcase
  end
endmodule