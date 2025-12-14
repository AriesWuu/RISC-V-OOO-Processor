module i_cache #(
  parameter WORDS = 512, // Number of words in the cache, 512 * 4=2kB
  parameter string MEMFILE = "" // Memory initialization file
)(
  input  logic [31:0] addr,   // PC
  output logic [31:0] instr   // Instruction
);
  // Memory array to hold instructions (byte-addressable)
  logic [7:0] mem [0:(WORDS*4)-1];

  // Initialize memory from a file (optional)
  // Input file format: (1 byte per line)
  initial begin
    // First initialize all memory to 0 (prevents X propagation)
    for (int i = 0; i < WORDS*4; i++) begin
      mem[i] = 8'h00;
    end
    // Then load the program
    if (MEMFILE != "") begin
      $readmemh(MEMFILE, mem);
    end
  end

  // Instruction fetch logic (little-endian assembly)
  always_comb begin
    logic [31:0] base;
    base  = {addr[31:2], 2'b00};            // word-align
    instr = { mem[base+3], mem[base+2],     // MSB <- high address
              mem[base+1], mem[base+0] };   // LSB <- low address
  end

endmodule
