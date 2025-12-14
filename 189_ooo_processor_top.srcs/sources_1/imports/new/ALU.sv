import cpu_pkg::*;

module ALU_unit (
  input  logic         clk,
  input  logic         reset,
  input  logic         flush_i, // Recovery flush

  // Issue interface
  input  logic         valid_i,
  input  rs_pkt_t      pkt_i,
  input  logic [31:0]  src0_data_i,
  input  logic [31:0]  src1_data_i,
  output logic         ready_o, // To RS (always ready in 1-cycle ALU)

  // Writeback interface
  output logic         wb_valid_o,
  output logic [31:0]  wb_data_o,
  output logic [6:0]   wb_dst_prf_o,
  output logic [$clog2(ROB_ENTRIES)-1:0] wb_rob_tag_o
);

  // ALU is 1 cycle, so we can just register the inputs/results
  // Cycle 0: Issue (valid_i=1). Data is available at src0_data_i.
  // Cycle 1: Writeback.
  
  assign ready_o = 1'b1; // Always ready to accept new instruction (pipelined 1 cycle)

  // Decode control signals from micro_op field
  // micro_op[3:0] = alu_ctrl (from alu_control module)
  // micro_op[4]   = aluSrc (1: use immediate, 0: use src1)
  //   ALU_ADD  = 4'd0 - ADD / address calc
  //   ALU_SUB  = 4'd1 - SUB / branch compare
  //   ALU_AND  = 4'd2 - AND
  //   ALU_OR   = 4'd3 - OR (ORI)
  //   ALU_SRA  = 4'd4 - arithmetic shift right
  //   ALU_SLTU = 4'd5 - set-less-than unsigned (SLTIU)
  //   ALU_LUI  = 4'd6 - LUI
  logic [3:0] alu_ctrl;
  logic       alu_src;
  assign alu_ctrl = pkt_i.micro_op[3:0];
  assign alu_src  = pkt_i.micro_op[4]; // 1 = use immediate, 0 = use src1

  // Select operand B based on aluSrc
  logic [31:0] operand_b;
  assign operand_b = alu_src ? pkt_i.imm : src1_data_i;

  // Combinational ALU result
  logic [31:0] alu_result;
  always_comb begin
    case (alu_ctrl)
      4'd0: alu_result = src0_data_i + operand_b;                            // ADD/ADDI
      4'd1: alu_result = src0_data_i - operand_b;                            // SUB
      4'd2: alu_result = src0_data_i & operand_b;                            // AND/ANDI
      4'd3: alu_result = src0_data_i | operand_b;                            // OR/ORI
      4'd4: alu_result = $signed(src0_data_i) >>> operand_b[4:0];            // SRA/SRAI
      4'd5: alu_result = (src0_data_i < operand_b) ? 32'b1 : 32'b0;          // SLTU/SLTIU
      4'd6: alu_result = pkt_i.imm;                                          // LUI (always use imm)
      default: alu_result = 32'b0;
    endcase
  end

  always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
      wb_valid_o   <= 1'b0;
      wb_data_o    <= '0;
      wb_dst_prf_o <= '0;
      wb_rob_tag_o <= '0;
    end else begin
      // Let all in-flight operations complete, even during recovery
      wb_valid_o <= valid_i;
      if (valid_i) begin
        wb_dst_prf_o <= pkt_i.dst_prf;
        wb_rob_tag_o <= pkt_i.rob_tag;
        wb_data_o    <= alu_result;
      end
    end
  end
endmodule