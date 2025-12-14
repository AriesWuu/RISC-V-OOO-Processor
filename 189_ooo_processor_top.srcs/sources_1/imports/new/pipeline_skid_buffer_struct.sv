module pipeline_skid_buffer_struct #(
  parameter type T = logic                                // Data width    
) (
  input  logic clk,
  input  logic reset,
  input  logic flush,

  // upstream (producer -> skid)
  input  logic valid_in,
  output logic ready_in,
  input  T     data_in,

  // downstream (skid -> consumer)
  output logic valid_out,
  input  logic ready_out,
  output T     data_out
);
  // Internal signals 
  // ===========================================
  logic bypass;                 // skid condition
  logic hold_condition;         // need to capture skid data
  T     data_reg;               // output register (1-cycle latency)
  T     data_skid;              // skid register (captures one extra item)
  logic valid_reg;              // output valid register

  // Accept when downstream is ready OR when output register is empty.
  // In skid mode (bypass==0), stall upstream until downstream consumes data_reg.
  assign ready_in = (bypass) ? (ready_out || !valid_reg) : 1'b0;

  // hold condition logic
  assign hold_condition = valid_in && !ready_out;

  // Combinational outputs
  assign data_out  = data_reg;
  assign valid_out = valid_reg;

  // Sequential Logic
  always_ff @(posedge clk) begin
    if (reset || flush) begin
      bypass    <= 1'b1;
      valid_reg <= 1'b0;
      data_reg  <= '0;
      data_skid <= '0;
    end else begin
      case (bypass)
        1'b1: begin
          if (ready_out || !valid_reg) begin
            // can accept new data into the output register
            data_reg  <= data_in;
            valid_reg <= valid_in;
          end else if (hold_condition) begin
            // downstream stalled while holding a valid entry: capture one skid item
            data_skid <= data_in;
            bypass    <= 1'b0;
          end
        end
        1'b0: begin
          if (ready_out) begin
            // downstream is ready: move skid item into output register
            data_reg  <= data_skid;
            valid_reg <= 1'b1;
            bypass    <= 1'b1;
          end
        end
      endcase
    end
  end
endmodule