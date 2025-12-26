// BRAM model for data memory with 2-cycle read latency and byte write enable
// Clock gating enabled for low power design
`timescale 1ns / 1ps
module data_memory #(
    parameter int WORDS = 1024
)(
    input  logic        clk,
    // Read port (2-cycle latency)
    input  logic        re,      // Read enable for clock gating
    input  logic [31:0] raddr,
    // Write port
    input  logic [3:0]  we,      // Write byte enable: we[0]=byte0, we[1]=byte1, etc.
    input  logic [31:0] waddr,
    input  logic [31:0] wdata,
    output logic [31:0] rdata
);
    // Strict single-port synchronous BRAM model with fixed 2-cycle read latency
    // - Cycle 0: register read address when re=1
    // - Cycle 1: read memory into internal register
    // - Cycle 2: register rdata output
    
    logic [31:0] mem [0:WORDS-1];
    logic [31:0] r_word_addr_now;
    logic [31:0] w_word_addr_now;
    assign r_word_addr_now = raddr[31:2]; // Word aligned address
    assign w_word_addr_now = waddr[31:2]; // Word aligned address

    logic [31:0] rd_addr_d0;
    logic [31:0] rdata_reg;  // Stage 1 register
    logic        re_d0;
    logic        re_d1;
    
    // Write port (synchronous)
    always_ff @(posedge clk) begin
        if (|we) begin
            if (we[0]) mem[w_word_addr_now][7:0]   <= wdata[7:0];
            if (we[1]) mem[w_word_addr_now][15:8]  <= wdata[15:8];
            if (we[2]) mem[w_word_addr_now][23:16] <= wdata[23:16];
            if (we[3]) mem[w_word_addr_now][31:24] <= wdata[31:24];
        end
    end

    // Cycle 0: register read address
    always_ff @(posedge clk) begin
        if (re) begin
            rd_addr_d0 <= r_word_addr_now;
        end
        re_d0 <= re;
    end

    // Cycle 1: memory read into internal register
    always_ff @(posedge clk) begin
        if (re_d0) begin
            rdata_reg <= mem[rd_addr_d0];
        end
        re_d1 <= re_d0;
    end

    // Cycle 2: register output
    always_ff @(posedge clk) begin
        if (re_d1) begin
            rdata <= rdata_reg;
        end
    end
    
    // Initial block for testing
    initial begin
        integer i;
        for (i=0; i<WORDS; i++) mem[i] = 32'h0;
    end

endmodule