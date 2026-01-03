module i_cache #(
  parameter WORDS = 512, // Number of words in the cache, 512 * 4=2kB
  parameter string MEMFILE = "" // Memory initialization file
)(
  input  logic [31:0] addr0,   // PC for first instruction
  input  logic [31:0] addr1,   // PC for second instruction (typically PC+4)
  output logic [31:0] instr0,  // First instruction
  output logic [31:0] instr1   // Second instruction
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

  // Dual-port instruction fetch logic (little-endian assembly)
  always_comb begin
    logic [31:0] base0, base1;

    // Port 0: First instruction
    base0   = {addr0[31:2], 2'b00};          // word-align
    instr0  = { mem[base0+3], mem[base0+2],  // MSB <- high address
                mem[base0+1], mem[base0+0] }; // LSB <- low address

    // Port 1: Second instruction
    base1   = {addr1[31:2], 2'b00};          // word-align
    instr1  = { mem[base1+3], mem[base1+2],  // MSB <- high address
                mem[base1+1], mem[base1+0] }; // LSB <- low address
  end

endmodule
