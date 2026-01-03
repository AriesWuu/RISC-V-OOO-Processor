// Map Table with dual-issue support (4-read, 2-write) and RAW/WAW detection
// Handles intra-pair dependencies for dual-issue rename
module map_table #(
  parameter int ARCH_REGS   = 32,
  parameter int ROB_ENTRIES = 16
)(
  input logic clk,
  input logic reset,

  // Dual-issue read addresses from rename (instruction 0 and instruction 1)
  input logic [4:0] rs1_arch_0,   // Instruction 0 source 1
  input logic [4:0] rs2_arch_0,   // Instruction 0 source 2
  input logic [4:0] rd_arch_0,    // Instruction 0 destination
  input logic [4:0] rs1_arch_1,   // Instruction 1 source 1
  input logic [4:0] rs2_arch_1,   // Instruction 1 source 2
  input logic [4:0] rd_arch_1,    // Instruction 1 destination

  // Dual-issue write enables
  input logic       wr_en_0,      // Instruction 0 writes destination
  input logic       wr_en_1,      // Instruction 1 writes destination

  // New physical register allocations from free list
  input logic [6:0] rd_prf_0,     // Instruction 0 new physical register
  input logic [6:0] rd_prf_1,     // Instruction 1 new physical register

  // Branch checkpoint / recovery
  input  logic       branch_checkpoint,
  input  logic [$clog2(ROB_ENTRIES)-1:0] checkpoint_tag,
  input  logic       branch_recover,
  input  logic [$clog2(ROB_ENTRIES)-1:0] recover_tag,

  // Output: Physical register mappings (with RAW/WAW hazard forwarding)
  // Instruction 0 outputs
  output logic [6:0] rs1_prf_0,
  output logic [6:0] rs2_prf_0,
  output logic [6:0] rd_old_prf_0,  // Old PRF for instruction 0 (for free list)

  // Instruction 1 outputs (includes RAW/WAW forwarding from instruction 0)
  output logic [6:0] rs1_prf_1,
  output logic [6:0] rs2_prf_1,
  output logic [6:0] rd_old_prf_1   // Old PRF for instruction 1 (with WAW handling)
);

  logic [6:0] map [0:ARCH_REGS-1];
  // Multiple checkpoints indexed by ROB tag
  logic [6:0] map_cp [0:ROB_ENTRIES-1][0:ARCH_REGS-1];

  // =====================================================================
  // Combinational Read Logic with RAW/WAW Hazard Detection
  // =====================================================================
  // Instruction 0: Simple map table read (no dependency on instruction 1)
  assign rs1_prf_0    = map[rs1_arch_0];
  assign rs2_prf_0    = map[rs2_arch_0];
  assign rd_old_prf_0 = map[rd_arch_0];

  // Instruction 1: Check for RAW and WAW dependencies with instruction 0
  // RAW: If instruction 1 reads a register that instruction 0 writes,
  //      forward instruction 0's NEW physical register
  // WAW: If instruction 1 writes the same architectural register as instruction 0,
  //      the old physical register should be instruction 0's NEW allocation

  logic raw_rs1_match, raw_rs2_match, waw_match;

  assign raw_rs1_match = wr_en_0 && (rs1_arch_1 == rd_arch_0) && (rd_arch_0 != 5'd0);
  assign raw_rs2_match = wr_en_0 && (rs2_arch_1 == rd_arch_0) && (rd_arch_0 != 5'd0);
  assign waw_match     = wr_en_0 && wr_en_1 && (rd_arch_1 == rd_arch_0) && (rd_arch_0 != 5'd0);

  // Instruction 1 source register mappings with RAW forwarding
  assign rs1_prf_1 = raw_rs1_match ? rd_prf_0 : map[rs1_arch_1];
  assign rs2_prf_1 = raw_rs2_match ? rd_prf_0 : map[rs2_arch_1];

  // Instruction 1 old physical register with WAW handling
  // If both instructions write to the same architectural register,
  // instruction 1's old_prf should be instruction 0's NEW physical register
  assign rd_old_prf_1 = waw_match ? rd_prf_0 : map[rd_arch_1];

  // =====================================================================
  // Sequential Write Logic and Checkpoint Management
  // =====================================================================
  integer i, j;
  always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
      // Initialize map: architectural register i -> physical register i
      for (i=0; i<ARCH_REGS; i++) begin
        map[i] <= i[6:0];
      end
      // Initialize all checkpoints
      for (j=0; j<ROB_ENTRIES; j++) begin
        for (i=0; i<ARCH_REGS; i++) begin
          map_cp[j][i] <= i[6:0];
        end
      end
    end else begin
      if (branch_recover) begin
        // Restore from the checkpoint indexed by recover_tag
        for (i=0; i<ARCH_REGS; i++) begin
          map[i] <= map_cp[recover_tag][i];
        end
      end else begin
        // Dual-issue map table update
        // Priority: Instruction 1 overwrites instruction 0 if both write to same register
        if (wr_en_0 && (rd_arch_0 != 5'd0)) begin
          map[rd_arch_0] <= rd_prf_0;
        end
        if (wr_en_1 && (rd_arch_1 != 5'd0)) begin
          map[rd_arch_1] <= rd_prf_1;  // Overwrites instr0 if WAW
        end

        // Save checkpoint at the specified ROB tag
        // Checkpoint should capture the state AFTER both instructions update
        if (branch_checkpoint) begin
          for (i=0; i<ARCH_REGS; i++) begin
            logic [4:0] i_arch;
            i_arch = i[4:0];

            // Determine what value to save based on dual-issue writes
            // Priority: instr1 > instr0 > current map
            if (wr_en_1 && (i_arch == rd_arch_1) && (rd_arch_1 != 5'd0))
              map_cp[checkpoint_tag][i] <= rd_prf_1;
            else if (wr_en_0 && (i_arch == rd_arch_0) && (rd_arch_0 != 5'd0))
              map_cp[checkpoint_tag][i] <= rd_prf_0;
            else
              map_cp[checkpoint_tag][i] <= map[i];
          end
        end
      end
    end
  end

endmodule
