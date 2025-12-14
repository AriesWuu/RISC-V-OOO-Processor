// rob_tag.sv
`timescale 1ns/1ps

module rob_tag #(
  parameter int ROB_ENTRIES = 16,
  localparam int TAGW = $clog2(ROB_ENTRIES)
)(
  input  logic clk,
  input  logic reset,
  input  logic inc_en,      // one instr enters rename
  output logic [TAGW-1:0] rob_tag,

  // branch checkpoint / recovery
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
        tag_cur <= tag_cp[recover_tag];  // rollback from indexed checkpoint
      end else begin
        if (inc_en) tag_cur <= tag_cur + 1'b1; // simple counter
        // Checkpoint AFTER increment so branch instruction's tag is included
        if (branch_checkpoint) begin
          if (inc_en)
            tag_cp[checkpoint_tag] <= tag_cur + 1'b1;
          else
            tag_cp[checkpoint_tag] <= tag_cur;
        end
      end
    end
  end

  assign rob_tag = tag_cur;
endmodule