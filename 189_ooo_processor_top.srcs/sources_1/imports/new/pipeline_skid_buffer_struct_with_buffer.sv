module pipeline_skid_buffer_struct_with_flush #(
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
  logic bypass;     // skid condition
  logic hold_condition; // condition to hold data
  T     data_reg;  // hold data register
  T     data_skid;  // skid data register
  logic   valid_reg;          // hold valid register
  logic   ready_reg;          //  hold ready register

    
  // hold condition logic
  assign hold_condition = valid_in && !ready_out && !flush; // need to hold data when input is valid but output is not ready

 // Combinational output Logic
  assign data_out = data_reg;                     // output data
  assign valid_out = valid_reg && !flush ;                   // output valid
  assign ready_in = ready_reg || flush;                    // input ready

  // Sequential Logic
  always_ff @(posedge clk) begin
    if (reset || flush) begin
      bypass    <= 1'b1;
      valid_reg <= 1'b0;
      ready_reg <= 1'b0;
      data_reg  <= '0;
      data_skid <= '0;
    end else begin
      // State machine
      case(bypass)
        1'b1: begin
          if (ready_out || !valid_reg) begin      // can accept new data
            data_reg  <= data_in;
            valid_reg <= valid_in;
            ready_reg <= 1'b1;
          end else if (hold_condition) begin      // need to hold data
            data_skid <= data_in;
            ready_reg <= 1'b0;
            bypass    <= 1'b0;     
          end
        end
        1'b0: begin
          if (ready_out) begin                    // downstream is ready
            data_reg  <= data_skid;
            valid_reg <= 1'b1;
            ready_reg <= 1'b1;
            bypass    <= 1'b1;
          end
        end
      endcase
    end
  end
endmodule

