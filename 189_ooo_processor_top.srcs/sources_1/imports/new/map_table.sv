module map_table #(
  parameter int ARCH_REGS   = 32,
  parameter int ROB_ENTRIES = 16
)(
  input logic clk, 
  input logic reset,

  // read addresses from decode/rename_top
  input logic [4:0] rs1_arch,
  input logic [4:0] rs2_arch,
  input logic [4:0] rd_arch,

  // write enable from rename_top
  input logic       wr_en_dst,
  // branch checkpoint / recovery
  input  logic       branch_checkpoint,
  input  logic [$clog2(ROB_ENTRIES)-1:0] checkpoint_tag,  // ROB tag to save checkpoint
  input  logic       branch_recover,
  input  logic [$clog2(ROB_ENTRIES)-1:0] recover_tag,     // ROB tag to restore from new physical from free list
  input logic [6:0] rd_prf,
  // results
  output logic [6:0] rs1_prf,
  output logic [6:0] rs2_prf,
  // old physical for free list
  output logic [6:0] rd_old_prf
);

  logic [6:0] map [0:ARCH_REGS-1];
  // Multiple checkpoints indexed by ROB tag
  logic [6:0] map_cp [0:ROB_ENTRIES-1][0:ARCH_REGS-1];

  // init: arch i -> phys i
  integer i, j;
  always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
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
        if (wr_en_dst) begin
          map[rd_arch] <= rd_prf;
        end
        // Save checkpoint at the specified ROB tag
        if (branch_checkpoint) begin
          for (i=0; i<ARCH_REGS; i++) begin
            // If writing to this register in the same cycle, save the new value
            if (wr_en_dst && (i[4:0] == rd_arch))
              map_cp[checkpoint_tag][i] <= rd_prf;
            else
              map_cp[checkpoint_tag][i] <= map[i];
          end
        end
      end
    end
  end

  // comb reads
  assign rs1_prf    = map[rs1_arch];
  assign rs2_prf    = map[rs2_arch];
  assign rd_old_prf = map[rd_arch];
endmodule