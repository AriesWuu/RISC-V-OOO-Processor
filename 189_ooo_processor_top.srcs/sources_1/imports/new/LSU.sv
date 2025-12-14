`timescale 1ns / 1ps
import cpu_pkg::*;

module LSU_unit (
  input  logic         clk,
  input  logic         reset,
  input  logic         flush_i,

  // Issue interface
  input  logic         valid_i,
  input  rs_pkt_t      pkt_i,
  input  logic [31:0]  src0_data_i, // Base address
  input  logic [31:0]  src1_data_i, // Store data (for SW)
  output logic         ready_o,

  // Writeback interface (for loads - writes PRF)
  output logic         wb_valid_o,
  output logic [31:0]  wb_data_o,
  output logic [6:0]   wb_dst_prf_o,
  output logic [$clog2(ROB_ENTRIES)-1:0] wb_rob_tag_o,
  
  // Memory Interface (directly to BRAM)
  output logic [31:0]  dmem_addr_o,
  output logic         dmem_re_o,     // Read enable for clock gating
  output logic [3:0]   dmem_we_o,     // Write byte enable (4-bit)
  output logic [31:0]  dmem_wdata_o,
  input  logic [31:0]  dmem_rdata_i
);

  // LSU micro_op encoding (from decode_module control signals):
  // micro_op[0] = lw (1: load operation)
  // micro_op[1] = sw (1: store operation)
  // micro_op[2] = loadByte (1: LBU, 0: LW) - only valid when lw=1
  // micro_op[3] = storeHalf (1: SH, 0: SW) - only valid when sw=1
  //
  // Resulting operations:
  //   lw=1, loadByte=0 -> LW  (Load Word)
  //   lw=1, loadByte=1 -> LBU (Load Byte Unsigned)
  //   sw=1, storeHalf=0 -> SW  (Store Word)
  //   sw=1, storeHalf=1 -> SH  (Store Halfword)
  
  // Pipeline aligned to strict 2-cycle synchronous BRAM read model:
  // - Cycle 0: present addr/re/we/wdata to BRAM
  // - Cycle 1: BRAM internal (address registered)
  // - Cycle 2: BRAM internal (data registered)
  // - Cycle 3: BRAM output visible on dmem_rdata_i -> LSU writeback
  // We therefore carry requests for 3 stages: s1/s2/s3.

  // Stage 1 registers
  logic        s1_valid;
  logic        s1_is_load;
  logic        s1_is_store;
  logic        s1_load_byte;  // 0: LW, 1: LBU
  logic [1:0]  s1_byte_offset;
  logic [31:0] s1_word_addr;
  logic [6:0]  s1_dst_prf;
  logic [$clog2(ROB_ENTRIES)-1:0] s1_rob_tag;

  // Stage 2 registers
  logic        s2_valid;
  logic        s2_is_load;
  logic        s2_is_store;
  logic        s2_load_byte;
  logic [1:0]  s2_byte_offset;
  logic [31:0] s2_word_addr;
  logic [6:0]  s2_dst_prf;
  logic [$clog2(ROB_ENTRIES)-1:0] s2_rob_tag;

  // Stage 3 registers (align to BRAM rdata)
  logic        s3_valid;
  logic        s3_is_load;
  logic        s3_is_store;
  logic        s3_load_byte;
  logic [1:0]  s3_byte_offset;
  logic [31:0] s3_word_addr;
  logic [6:0]  s3_dst_prf;
  logic [$clog2(ROB_ENTRIES)-1:0] s3_rob_tag;

  // Throughput-first: accept one mem op per cycle; squash new requests on flush
  assign ready_o = 1'b1;

  // Address Adder
  logic [31:0] addr_gen;
  assign addr_gen = src0_data_i + pkt_i.imm;
  
  // Decode LSU operation from control signals
  logic is_load, is_store, load_byte, store_half;
  assign is_load    = pkt_i.micro_op[0];
  assign is_store   = pkt_i.micro_op[1];
  assign load_byte  = pkt_i.micro_op[2];  // 1: LBU, 0: LW
  assign store_half = pkt_i.micro_op[3];  // 1: SH, 0: SW
  
  // Memory Control (Cycle 0 signals)
  assign dmem_addr_o = addr_gen;
  assign dmem_re_o   = valid_i && !flush_i && is_load;  // Read enable for clock gating
  
  // Write enable and data based on store type
  logic [1:0] store_byte_offset;
  assign store_byte_offset = addr_gen[1:0];
  
  always_comb begin
    if (valid_i && !flush_i && is_store) begin
      if (store_half) begin
        // SH (Store Halfword) - write 2 bytes
        if (store_byte_offset[1]) begin
          // Upper halfword (bytes 2-3)
          dmem_we_o    = 4'b1100;
          dmem_wdata_o = {src1_data_i[15:0], 16'b0};
        end else begin
          // Lower halfword (bytes 0-1)
          dmem_we_o    = 4'b0011;
          dmem_wdata_o = {16'b0, src1_data_i[15:0]};
        end
      end else begin
        // SW (Store Word) - write all 4 bytes
        dmem_we_o    = 4'b1111;
        dmem_wdata_o = src1_data_i;
      end
    end else begin
      // No store - disable all writes
      dmem_we_o    = 4'b0000;
      dmem_wdata_o = '0;
    end
  end

  // ------------------------------------------------------------
  // Simple 2-entry store buffer (for store→load forwarding)
  // - Keeps the last 2 stores in program order
  // - Loads merge bytes from matching store(s) at response time
  // ------------------------------------------------------------
  logic        sb0_valid, sb1_valid;
  logic [31:0] sb0_word_addr, sb1_word_addr;
  logic [3:0]  sb0_be, sb1_be;
  logic [31:0] sb0_wdata, sb1_wdata;

  logic issue_store_d0;
  assign issue_store_d0 = valid_i && !flush_i && is_store;

  // Forwarding merge helpers
  function automatic [31:0] apply_be_merge(
    input logic [31:0] base,
    input logic [31:0] new_data,
    input logic [3:0]  be
  );
    logic [31:0] out;
    begin
      out = base;
      if (be[0]) out[7:0]   = new_data[7:0];
      if (be[1]) out[15:8]  = new_data[15:8];
      if (be[2]) out[23:16] = new_data[23:16];
      if (be[3]) out[31:24] = new_data[31:24];
      apply_be_merge = out;
    end
  endfunction

  always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
      s1_valid       <= 1'b0;
      s1_is_load     <= 1'b0;
      s1_is_store    <= 1'b0;
      s1_load_byte   <= 1'b0;
      s1_byte_offset <= 2'b0;
      s1_dst_prf     <= '0;
      s1_rob_tag     <= '0;
      
      s2_valid       <= 1'b0;
      s2_is_load     <= 1'b0;
      s2_is_store    <= 1'b0;
      s2_load_byte   <= 1'b0;
      s2_byte_offset <= 2'b0;
      s2_word_addr   <= '0;
      s2_dst_prf     <= '0;
      s2_rob_tag     <= '0;

      s3_valid       <= 1'b0;
      s3_is_load     <= 1'b0;
      s3_is_store    <= 1'b0;
      s3_load_byte   <= 1'b0;
      s3_byte_offset <= 2'b0;
      s3_word_addr   <= '0;
      s3_dst_prf     <= '0;
      s3_rob_tag     <= '0;

      sb0_valid      <= 1'b0;
      sb1_valid      <= 1'b0;
      sb0_word_addr  <= '0;
      sb1_word_addr  <= '0;
      sb0_be         <= 4'b0;
      sb1_be         <= 4'b0;
      sb0_wdata      <= '0;
      sb1_wdata      <= '0;
      
      wb_valid_o     <= 1'b0;
      wb_data_o      <= '0;
      wb_dst_prf_o   <= '0;
      wb_rob_tag_o   <= '0;
    end else begin
      // On flush: block new issues, let in-flight operations complete
      s1_valid       <= (!flush_i) && valid_i && (is_load || is_store);
      s1_is_load     <= is_load;
      s1_is_store    <= is_store;
      s1_load_byte   <= load_byte;          // 0: LW, 1: LBU
      s1_byte_offset <= addr_gen[1:0];
      s1_word_addr   <= addr_gen[31:2];
      s1_dst_prf     <= pkt_i.dst_prf;
      s1_rob_tag     <= pkt_i.rob_tag;
      
      // Stage 1 -> 2: BRAM latency cycle 1
      s2_valid       <= s1_valid;
      s2_is_load     <= s1_is_load;
      s2_is_store    <= s1_is_store;
      s2_load_byte   <= s1_load_byte;
      s2_byte_offset <= s1_byte_offset;
      s2_word_addr   <= s1_word_addr;
      s2_dst_prf     <= s1_dst_prf;
      s2_rob_tag     <= s1_rob_tag;

      // Stage 2 -> 3: BRAM latency cycle 2 (align to output rdata)
      s3_valid       <= s2_valid;
      s3_is_load     <= s2_is_load;
      s3_is_store    <= s2_is_store;
      s3_load_byte   <= s2_load_byte;
      s3_byte_offset <= s2_byte_offset;
      s3_word_addr   <= s2_word_addr;
      s3_dst_prf     <= s2_dst_prf;
      s3_rob_tag     <= s2_rob_tag;

      // Store buffer update (keep last 2 stores in order)
      if (flush_i) begin
        sb0_valid <= 1'b0;
        sb1_valid <= 1'b0;
      end else if (issue_store_d0) begin
        if (!sb0_valid) begin
          sb0_valid     <= 1'b1;
          sb0_word_addr <= addr_gen[31:2];
          sb0_be        <= dmem_we_o;
          sb0_wdata     <= dmem_wdata_o;
        end else if (!sb1_valid) begin
          sb1_valid     <= 1'b1;
          sb1_word_addr <= addr_gen[31:2];
          sb1_be        <= dmem_we_o;
          sb1_wdata     <= dmem_wdata_o;
        end else begin
          // full: drop oldest
          sb0_valid     <= sb1_valid;
          sb0_word_addr <= sb1_word_addr;
          sb0_be        <= sb1_be;
          sb0_wdata     <= sb1_wdata;

          sb1_valid     <= 1'b1;
          sb1_word_addr <= addr_gen[31:2];
          sb1_be        <= dmem_we_o;
          sb1_wdata     <= dmem_wdata_o;
        end
      end
      
      // Stage 3 -> WB: BRAM output visible
      wb_valid_o   <= s3_valid;
      wb_rob_tag_o <= s3_rob_tag;

      if (s3_valid && s3_is_load) begin
        // Load writeback (writes to PRF)
        logic [31:0] merged_word;
        merged_word = dmem_rdata_i;

        if (sb0_valid && (sb0_word_addr == s3_word_addr)) begin
          merged_word = apply_be_merge(merged_word, sb0_wdata, sb0_be);
        end
        if (sb1_valid && (sb1_word_addr == s3_word_addr)) begin
          merged_word = apply_be_merge(merged_word, sb1_wdata, sb1_be);
        end

        wb_dst_prf_o <= s3_dst_prf;

        // Load data extraction based on type and byte offset
        if (s3_load_byte) begin
          // LBU (Load Byte Unsigned) - extract byte from 32-bit word
          case (s3_byte_offset)
            2'b00: wb_data_o <= {24'b0, merged_word[7:0]};
            2'b01: wb_data_o <= {24'b0, merged_word[15:8]};
            2'b10: wb_data_o <= {24'b0, merged_word[23:16]};
            2'b11: wb_data_o <= {24'b0, merged_word[31:24]};
          endcase
        end else begin
          // LW (Load Word)
          wb_data_o <= merged_word;
        end
      end else if (s3_valid && s3_is_store) begin
        // Store completion (only signals ROB, no PRF write)
        wb_dst_prf_o <= '0;  // Store doesn't write to PRF
        wb_data_o    <= '0;
      end else begin
        wb_dst_prf_o <= '0;
        wb_data_o    <= '0;
      end
    end
  end

endmodule