// Free List with dual-issue support (dual allocation and dual retire)
module free_list #(
  parameter int ARCH_REGS   = 32,
  parameter int PHYS_REGS   = 96,
  parameter int ROB_ENTRIES = 16
)(
  input  logic       clk,
  input  logic       reset,

  // Dual retire interface (up to 2 registers returned per cycle)
  input  logic       retire_en_0,      // Return first physical register
  input  logic       retire_en_1,      // Return second physical register
  input  logic [6:0] retired_preg_0,   // First physical register being freed
  input  logic [6:0] retired_preg_1,   // Second physical register being freed

  // Dual allocate interface (up to 2 registers allocated per cycle)
  input  logic       allocate_en_0,    // Allocate first physical register
  input  logic       allocate_en_1,    // Allocate second physical register
  output logic       alloc_rdy_0,      // At least 1 free register available
  output logic       alloc_rdy_1,      // At least 2 free registers available
  output logic [6:0] new_preg_0,       // First allocated physical register
  output logic [6:0] new_preg_1,       // Second allocated physical register

  // Branch checkpoint/recovery
  input  logic       branch_checkpoint,
  input  logic [$clog2(ROB_ENTRIES)-1:0] checkpoint_tag,
  input  logic       branch_recover,
  input  logic [$clog2(ROB_ENTRIES)-1:0] recover_tag
);

  // Free-list holds the pool of physical registers NOT currently assigned
  localparam int FREE_REGS = (PHYS_REGS > ARCH_REGS) ? (PHYS_REGS - ARCH_REGS) : 1;

  // Storage for free-list order
  logic [6:0] buffer_mem [0:FREE_REGS-1];

  // Pointer bits with flip bit for full/empty detection
  localparam int INDEX_BITS = $clog2(FREE_REGS);
  logic [INDEX_BITS:0] wr_ptr, rd_ptr;
  // Multiple checkpoints indexed by ROB tag
  logic [INDEX_BITS:0] wr_ptr_cp [0:ROB_ENTRIES-1];
  logic [INDEX_BITS:0] rd_ptr_cp [0:ROB_ENTRIES-1];

  integer i;

  // Helper function to bump pointer (with wrap-around and flip bit)
  function automatic logic [INDEX_BITS:0] bump(input logic [INDEX_BITS:0] p);
    bump = (p[INDEX_BITS-1:0] == FREE_REGS-1) ? {~p[INDEX_BITS], {(INDEX_BITS){1'b0}}} : (p + 1'b1);
  endfunction

  // Helper function to bump pointer by 2
  function automatic logic [INDEX_BITS:0] bump2(input logic [INDEX_BITS:0] p);
    bump2 = bump(bump(p));
  endfunction

  // Count number of free registers (combinational logic)
  logic [INDEX_BITS:0] num_free;
  always_comb begin
    if (wr_ptr[INDEX_BITS] == rd_ptr[INDEX_BITS]) begin
      // Same flip bit: free = wr - rd
      num_free = wr_ptr[INDEX_BITS-1:0] - rd_ptr[INDEX_BITS-1:0];
    end else begin
      // Different flip bit: free = (FREE_REGS - rd) + wr
      num_free = (FREE_REGS - rd_ptr[INDEX_BITS-1:0]) + wr_ptr[INDEX_BITS-1:0];
    end
  end

  // Ready signals
  assign alloc_rdy_0 = (num_free >= 1);  // At least 1 free
  assign alloc_rdy_1 = (num_free >= 2);  // At least 2 free

  // Allocation outputs
  assign new_preg_0 = buffer_mem[rd_ptr[INDEX_BITS-1:0]];
  assign new_preg_1 = buffer_mem[bump(rd_ptr)[INDEX_BITS-1:0]];

  logic retire_dual;
  always_ff @(posedge clk) begin
    if (reset) begin
      // Initialize pointers: rd at 0, wr at 0 with flip bit set (full state)
      rd_ptr    <= {1'b0, {(INDEX_BITS){1'b0}}};
      wr_ptr    <= {1'b1, {(INDEX_BITS){1'b0}}};

      // Initialize all checkpoints to match initial state
      for (i = 0; i < ROB_ENTRIES; i = i + 1) begin
        rd_ptr_cp[i] <= {1'b0, {(INDEX_BITS){1'b0}}};
        wr_ptr_cp[i] <= {1'b1, {(INDEX_BITS){1'b0}}};
      end

      // Initialize buffer with free physical registers (32-127 for 128 total)
      for (i = 0; i < FREE_REGS; i = i + 1) begin
        buffer_mem[i] <= i + ARCH_REGS[6:0];
      end
    end else begin
      // Branch recovery: restore pointers from checkpoint
      if (branch_recover) begin
        wr_ptr <= wr_ptr_cp[recover_tag];
        rd_ptr <= rd_ptr_cp[recover_tag];
      end else begin
        // Dual allocation logic (advance read pointer by 0, 1, or 2)
        logic allocate_dual;
        allocate_dual = allocate_en_0 && allocate_en_1 && alloc_rdy_1;

        if (allocate_dual) begin
          // Allocate 2 registers
          rd_ptr <= bump2(rd_ptr);
        end else if (allocate_en_0 && alloc_rdy_0) begin
          // Allocate 1 register
          rd_ptr <= bump(rd_ptr);
        end

        // Dual retire logic (write back up to 2 physical registers)
        retire_dual = retire_en_0 && retire_en_1;

        if (retire_dual) begin
          // Retire 2 registers
          buffer_mem[wr_ptr[INDEX_BITS-1:0]]       <= retired_preg_0;
          buffer_mem[bump(wr_ptr)[INDEX_BITS-1:0]] <= retired_preg_1;
          wr_ptr <= bump2(wr_ptr);
        end else if (retire_en_0) begin
          // Retire 1 register (instruction 0)
          buffer_mem[wr_ptr[INDEX_BITS-1:0]] <= retired_preg_0;
          wr_ptr <= bump(wr_ptr);
        end else if (retire_en_1) begin
          // Retire 1 register (instruction 1 only, rare case)
          buffer_mem[wr_ptr[INDEX_BITS-1:0]] <= retired_preg_1;
          wr_ptr <= bump(wr_ptr);
        end

        // Branch checkpoint save (after allocation/retirement)
        if (branch_checkpoint) begin
          wr_ptr_cp[checkpoint_tag] <= wr_ptr;

          // Save rd_ptr accounting for dual allocation
          if (allocate_dual)
            rd_ptr_cp[checkpoint_tag] <= bump2(rd_ptr);
          else if (allocate_en_0 && alloc_rdy_0)
            rd_ptr_cp[checkpoint_tag] <= bump(rd_ptr);
          else
            rd_ptr_cp[checkpoint_tag] <= rd_ptr;
        end
      end
    end
  end

`ifndef SYNTHESIS
  initial begin
    if (PHYS_REGS <= ARCH_REGS) begin
      $fatal(1, "free_list: PHYS_REGS (%0d) must be > ARCH_REGS (%0d)", PHYS_REGS, ARCH_REGS);
    end
  end
`endif
endmodule
