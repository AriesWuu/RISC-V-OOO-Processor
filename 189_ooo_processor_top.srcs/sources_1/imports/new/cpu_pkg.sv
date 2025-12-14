`timescale 1ns/1ps

package cpu_pkg;
  parameter integer PHYS_REGS    = 128;
  parameter integer ROB_ENTRIES  = 16;
  parameter integer IMM_BITS     = 32;  // RV32I

  localparam int PRF_BITS = $clog2(PHYS_REGS);
  localparam int ROB_BITS = $clog2(ROB_ENTRIES);

  // Decode packet structure (between decode and rename)
  // =====================================================
  typedef struct packed {
    logic [31:0] pc;           // Program counter
    logic        pred_hit;     // BTB hit at fetch for this PC
    logic        pred_taken;   // predicted taken at fetch
    logic [31:0] pred_target;  // predicted target (valid when pred_taken && pred_hit)
    logic [4:0]  srcReg1;      // Source register 1 (architectural)
    logic [4:0]  srcReg2;      // Source register 2 (architectural)
    logic [4:0]  destReg;      // Destination register (architectural)
    logic [31:0] imm;          // Immediate value
    logic [1:0]  fu;           // Function unit: 00-ALU, 01-Branch, 10-LSU
    logic        regWrite;     // Register write enable
    logic        aluSrc;       // ALU source: 1-immediate, 0-register
    logic        branch;       // Branch instruction
    logic        isJump;       // Jump instruction (JALR)
    logic        memRead;      // Load operation
    logic        memWrite;     // Store operation
    logic        loadByte;     // Load byte unsigned (LBU)
    logic        storeHalf;    // Store halfword (SH)
    logic [3:0]  alu_ctrl;     // ALU control signal
  } decode_pkt_t;



  // Rename packet structure (between rename and dispatch)
  // =====================================================
  typedef struct packed {
    logic [6:0]          micro_op;
    logic [PRF_BITS-1:0] dst_prf_new;   // new PRF to be written back at commit
    logic [PRF_BITS-1:0] dst_prf_old;   // previous PRF for map-table rollback
    logic [PRF_BITS-1:0] src0_prf;
    logic [PRF_BITS-1:0] src1_prf;
    logic [IMM_BITS-1:0] imm;
    logic [1:0]          fu;            // 0-ALU, 1-Branch, 2-LSU
    logic                is_branch;
    logic                writes_rd;
    logic [ROB_BITS-1:0] rob_tag;
    logic [31:0]         pc;            // instruction PC (for branch target calc)
    logic                pred_hit;
    logic                pred_taken;
    logic [31:0]         pred_target;
  } rename_pkt_t;



  // Reservation Station packet structure
  // =====================================================
  // micro_op[6:0] encoding depends on fu (function unit):
  //   fu=00 (ALU):    {2'b00, aluSrc, alu_ctrl[3:0]}
  //                   alu_ctrl: 0=ADD, 1=SUB, 2=AND, 3=OR, 4=SRA, 5=SLTU, 6=LUI
  //   fu=01 (Branch): {5'b00000, isJump, branch}
  //                   branch=1 -> BNE, isJump=1 -> JALR
  //   fu=10 (LSU):    {3'b000, storeHalf, loadByte, memWrite, memRead}
  //                   memRead=1 -> Load, memWrite=1 -> Store
  //                   loadByte=1 -> LBU, storeHalf=1 -> SH
  // =====================================================
  typedef struct packed {
    logic                valid;      // Slot occupied flag
    logic [6:0]          micro_op;   // Micro-op encoding (see above, different from RISC-V opcode)
    logic [PRF_BITS-1:0] dst_prf;    // Destination physical register number
    logic [PRF_BITS-1:0] src0_prf;   // Source 0 physical register number
    logic                src0_ready; // Source 0 ready flag (optional: RS can compute dynamically)
    logic [PRF_BITS-1:0] src1_prf;   // Source 1 physical register number
    logic                src1_ready; // Source 1 ready flag (optional)
    logic [IMM_BITS-1:0] imm;        // Immediate value / offset
    logic [1:0]          fu;         // Target function unit: 00-ALU, 01-Branch, 10-LSU
    logic [ROB_BITS-1:0] rob_tag;    // ROB entry index for this instruction
    logic [31:0]         pc;         // Instruction PC (for branch target calculation and JALR)
    logic                pred_hit;
    logic                pred_taken;
    logic [31:0]         pred_target;
  } rs_pkt_t;

endpackage : cpu_pkg
