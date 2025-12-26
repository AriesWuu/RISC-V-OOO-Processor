module free_list #(
  parameter int ARCH_REGS   = 32,
  parameter int PHYS_REGS   = 96,
  parameter int ROB_ENTRIES = 16
)(
  input  logic       clk,
  input  logic       reset,
  input  logic       retire_en,        // return one physical register
  input  logic       allocate_en,      // allocate one physical register
  input  logic [6:0] retired_preg,     // physical register being freed
  input  logic       branch_checkpoint,
  input  logic [$clog2(ROB_ENTRIES)-1:0] checkpoint_tag,  // ROB tag to save checkpoint
  input  logic       branch_recover,
  input  logic [$clog2(ROB_ENTRIES)-1:0] recover_tag,     // ROB tag to restore from
  output logic       alloc_rdy,        // at least one free register available
  output logic [6:0] new_preg          // allocated physical register
);

  // Free-list holds the pool of physical registers NOT currently assigned
  // to architectural registers at reset. Treat PHYS_REGS as the total count.
  localparam int FREE_REGS = (PHYS_REGS > ARCH_REGS) ? (PHYS_REGS - ARCH_REGS) : 1;

  // Storage for free-list order (optional content tracking)
  logic [6:0] buffer_mem [0:FREE_REGS-1];

  // Pointer bits: index bits = $clog2(FREE_REGS); add flip bit => width = index_bits+1
  localparam int INDEX_BITS = $clog2(FREE_REGS);
  logic [INDEX_BITS:0] wr_ptr, rd_ptr;       // write (retire) / read (allocate) pointers
  // Multiple checkpoints indexed by ROB tag
  logic [INDEX_BITS:0] wr_ptr_cp [0:ROB_ENTRIES-1];
  logic [INDEX_BITS:0] rd_ptr_cp [0:ROB_ENTRIES-1];

  integer i;

  // Round-aware bump: toggle flip bit when wrapping last index
  function automatic logic [INDEX_BITS:0] bump(input logic [INDEX_BITS:0] p);
    bump = (p[INDEX_BITS-1:0] == FREE_REGS-1) ? {~p[INDEX_BITS], {(INDEX_BITS){1'b0}}} : (p + 1'b1);
  endfunction

  // Allocation ready when not empty
  assign alloc_rdy = !(wr_ptr == rd_ptr);

  // Current element to allocate
  assign new_preg = buffer_mem[rd_ptr[INDEX_BITS-1:0]];

  always_ff @(posedge clk) begin
    if (reset) begin
      // Initialize pointers at different rounds to indicate full list of initial entries
      // Start write pointer one slot behind read pointer with different flip bit -> full of data.
      rd_ptr    <= {1'b0, {(INDEX_BITS){1'b0}}};
      wr_ptr    <= {1'b1, {(INDEX_BITS){1'b0}}};
      // Initialize all checkpoints to match initial state
      for (i = 0; i < ROB_ENTRIES; i = i + 1) begin
        rd_ptr_cp[i] <= {1'b0, {(INDEX_BITS){1'b0}}};
        wr_ptr_cp[i] <= {1'b1, {(INDEX_BITS){1'b0}}};
      end
      for (i = 0; i < FREE_REGS; i = i + 1) begin
        buffer_mem[i] <= i + ARCH_REGS[6:0];
      end
    end else begin
      // Branch recover restore
      if (branch_recover) begin
        wr_ptr <= wr_ptr_cp[recover_tag];
        rd_ptr <= rd_ptr_cp[recover_tag];
      end else begin
        // Allocate (advance read pointer) only if requested and not empty
        if (allocate_en && alloc_rdy) begin
          rd_ptr <= bump(rd_ptr);
        end
        // Retire (write back)
        if (retire_en) begin
          buffer_mem[wr_ptr[INDEX_BITS-1:0]] <= retired_preg;
          wr_ptr <= bump(wr_ptr);
        end
        // Branch checkpoint save - AFTER allocation so branch's allocation is included
        if (branch_checkpoint) begin
          wr_ptr_cp[checkpoint_tag] <= wr_ptr;
          // If allocating in the same cycle, save the post-allocation rd_ptr
          if (allocate_en && alloc_rdy)
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