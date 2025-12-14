module alu_control (
  input  logic [1:0] ALUOp,    // 00: addr/PC add, 01: branch compare, 10: R/I-type ALU, 11: LUI
  input  logic [2:0] funct3,
  input  logic [6:0] funct7,   // for R-type: SUB/SRA use 0100000; for I-type this is imm[11:5]
  output logic [3:0] alu_ctrl  // ALU operation encoding
);

  // ALU operation encoding (keep stable; ALU may already rely on these)
  localparam logic [3:0]
    ALU_ADD   = 4'd0, // ADD / address calc / PC+4
    ALU_SUB   = 4'd1, // SUB / branch compare
    ALU_AND   = 4'd2, // AND
    ALU_OR    = 4'd3, // OR (used by ORI)
    ALU_SRA   = 4'd4, // arithmetic shift right
    ALU_SLTU  = 4'd5, // set-less-than unsigned (used by SLTIU)
    ALU_LUI   = 4'd6; // used for LUI

  always_comb begin
    alu_ctrl = ALU_ADD;    // safe default
    
    case (ALUOp)
      2'b00: begin
        // Address/PC operations: JALR → ADD, Load/Store address calc
        alu_ctrl = ALU_ADD;
      end

      2'b01: begin
        // Branch compare: only BNE is supported in this design
        // We still just do SUB and the top-level uses zero flag != 0 for BNE
        alu_ctrl = ALU_SUB;
      end

      2'b10: begin
        // R/I-type ALU subset only:
        // - ADDI         : funct3=000 → ADD  (never SUB here)
        // - SUB   (R)    : funct3=000 & funct7=0100000 → SUB
        // - ORI          : funct3=110 → OR
        // - SLTIU        : funct3=011 → SLTU
        // - SRA   (R)    : funct3=101 & funct7=0100000 → SRA
        // - SRAI (I)     : funct3=101 & funct7=0100000 → SRA
        // - AND   (R)    : funct3=111 → AND

        case (funct3)
          3'b000: begin
            // ADDI (funct7[5]=0) or SUB (funct7[5]=1)
            if (funct7 == 7'b0100000) begin
              alu_ctrl = ALU_SUB;   // SUB (R-type)
            end else begin
              alu_ctrl = ALU_ADD;   // ADD/ADDI
            end
          end
          3'b110: alu_ctrl = ALU_OR;    // ORI (I-type)
          3'b011: alu_ctrl = ALU_SLTU;  // SLTIU (I-type)
          3'b101: alu_ctrl = (funct7[5]) ? ALU_SRA : ALU_ADD;  // SRA/SRAI
          3'b111: alu_ctrl = ALU_AND;   // AND (R-type)
          default: alu_ctrl = ALU_ADD;
        endcase
      end
      
      2'b11: begin
        // LUI: rd <- imm_u (pass imm through ALU)
        alu_ctrl = ALU_LUI;
      end
      
      default: begin
        alu_ctrl = ALU_ADD;
      end
    endcase
  end

endmodule