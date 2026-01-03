// rob_tag.sv - ROB tag allocator with dual-issue support
`timescale 1ns/1ps

module rob_tag #(
  parameter int ROB_ENTRIES = 16,
  localparam int TAGW = $clog2(ROB_ENTRIES)
)(
  input  logic clk,
  input  logic reset,

  // Dual-issue increment control
  input  logic inc_en_0,         // First instruction enters rename
  input  logic inc_en_1,         // Second instruction enters rename

  // Dual ROB tag outputs
  output logic [TAGW-1:0] rob_tag_0,   // Tag for first instruction (current)
  output logic [TAGW-1:0] rob_tag_1,   // Tag for second instruction (current+1)

  // Branch checkpoint / recovery
  input  logic       branch_checkpoint,
  input  logic [TAGW-1:0] checkpoint_tag,  // ROB tag to save checkpoint
  input  logic       branch_recover,
  input  logic [TAGW-1:0] recover_tag      // ROB tag to restore from
);

  logic [TAGW-1:0] tag_cur;
  // Multiple checkpoints indexed by ROB tag
  logic [TAGW-1:0] tag_cp [0:ROB_ENTRIES-1];

  integer i;
  always_ff @(posedge clk) begin
    if (reset) begin
      tag_cur <= '0;
      for (i = 0; i < ROB_ENTRIES; i = i + 1) begin
        tag_cp[i] <= '0;
      end
    end else begin
      if (branch_recover) begin
        // Restore from checkpoint
        tag_cur <= tag_cp[recover_tag];
      end else begin
        // Dual-issue increment logic
        logic inc_dual;
        inc_dual = inc_en_0 && inc_en_1;

        if (inc_dual) begin
          // Both instructions valid: increment by 2
          tag_cur <= tag_cur + 2'd2;
        end else if (inc_en_0) begin
          // Only first instruction valid: increment by 1
          tag_cur <= tag_cur + 1'b1;
        end
        // else: no increment if neither instruction valid

        // Checkpoint save AFTER increment
        if (branch_checkpoint) begin
          if (inc_dual)
            tag_cp[checkpoint_tag] <= tag_cur + 2'd2;
          else if (inc_en_0)
            tag_cp[checkpoint_tag] <= tag_cur + 1'b1;
          else
            tag_cp[checkpoint_tag] <= tag_cur;
        end
      end
    end
  end

  // Output assignments
  assign rob_tag_0 = tag_cur;              // First instruction gets current tag
  assign rob_tag_1 = tag_cur + 1'b1;       // Second instruction gets current+1

endmodule
