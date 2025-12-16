`timescale 1ns / 1ps
import cpu_pkg::*;

// LSU with LSQ integration for OOO memory operations
module LSU_unit (
  input  logic         clk,
  input  logic         reset,
  input  logic         flush_i,

  // Issue interface from RS
  input  logic         valid_i,
  input  rs_pkt_t      pkt_i,
  input  logic [31:0]  src0_data_i,  // Base address
  input  logic [31:0]  src1_data_i,  // Store data (for SW)
  output logic         ready_o,

  // Writeback interface (for loads - writes PRF)
  output logic         wb_valid_o,
  output logic [31:0]  wb_data_o,
  output logic [6:0]   wb_dst_prf_o,
  output logic [$clog2(ROB_ENTRIES)-1:0] wb_rob_tag_o,
  
  // LSQ Store Write Interface (when store issues)
  output logic         lsq_store_valid_o,
  output logic [31:0]  lsq_store_addr_o,
  output logic [31:0]  lsq_store_data_o,
  output logic [3:0]   lsq_store_be_o,
  output logic [$clog2(ROB_ENTRIES)-1:0] lsq_store_rob_tag_o,
  
  // LSQ Load Forward Interface (at writeback stage)
  output logic         lsq_load_fwd_req_o,
  output logic [$clog2(ROB_ENTRIES)-1:0] lsq_load_fwd_rob_tag_o,
  output logic [31:0]  lsq_load_fwd_addr_o,
  input  logic         lsq_load_fwd_valid_i,
  input  logic [31:0]  lsq_load_fwd_data_i,
  input  logic [3:0]   lsq_load_fwd_be_i,

  // Memory Interface (loads read, stores write through LSQ commit)
  output logic [31:0]  dmem_addr_o,
  output logic         dmem_re_o,
  input  logic [31:0]  dmem_rdata_i
);

  // LSU micro_op encoding:
  // micro_op[0] = lw (1: load operation)
  // micro_op[1] = sw (1: store operation)
  // micro_op[2] = loadByte (1: LBU, 0: LW)
  // micro_op[3] = storeHalf (1: SH, 0: SW)

  // Pipeline: data_memory has fixed 2-cycle read latency (see data_memory.sv)
  // Internal control/data pipeline uses 3 stages (s1/s2/s3) so that s3 aligns with rdata.

  // Stage registers
  logic        s1_valid, s2_valid, s3_valid;
  logic        s1_is_load, s2_is_load, s3_is_load;
  logic        s1_is_store, s2_is_store, s3_is_store;
  logic        s1_load_byte, s2_load_byte, s3_load_byte;
  logic [1:0]  s1_byte_offset, s2_byte_offset, s3_byte_offset;
  logic [31:0] s1_addr, s2_addr, s3_addr;
  logic [6:0]  s1_dst_prf, s2_dst_prf, s3_dst_prf;
  logic [$clog2(ROB_ENTRIES)-1:0] s1_rob_tag, s2_rob_tag, s3_rob_tag;

  // Always ready (simplified - no stall)
  assign ready_o = 1'b1;

  // Address generation
  logic [31:0] addr_gen;
  assign addr_gen = src0_data_i + pkt_i.imm;
  
  // Decode LSU operation
  logic is_load, is_store, load_byte, store_half;
  assign is_load    = pkt_i.micro_op[0];
  assign is_store   = pkt_i.micro_op[1];
  assign load_byte  = pkt_i.micro_op[2];
  assign store_half = pkt_i.micro_op[3];
  
  // Byte enable calculation for stores
  logic [3:0] store_be;
  logic [31:0] store_data_aligned;
  logic [1:0] store_byte_offset;
  assign store_byte_offset = addr_gen[1:0];
  
  always_comb begin
    if (store_half) begin
      if (store_byte_offset[1]) begin
        store_be = 4'b1100;
        store_data_aligned = {src1_data_i[15:0], 16'b0};
      end else begin
        store_be = 4'b0011;
        store_data_aligned = {16'b0, src1_data_i[15:0]};
      end
    end else begin
      store_be = 4'b1111;
      store_data_aligned = src1_data_i;
    end
  end
  
  // LSQ Store Write (when store issues)
  assign lsq_store_valid_o   = valid_i && !flush_i && is_store;
  assign lsq_store_addr_o    = addr_gen;
  assign lsq_store_data_o    = store_data_aligned;
  assign lsq_store_be_o      = store_be;
  assign lsq_store_rob_tag_o = pkt_i.rob_tag;
  
  // Memory read for loads
  assign dmem_addr_o = addr_gen;
  assign dmem_re_o   = valid_i && !flush_i && is_load;
  
  // LSQ forwarding request (aligned with memory rdata availability)
  // data_memory updates rdata at cycle2; s3 aligns with that timing.
  assign lsq_load_fwd_req_o     = s3_valid && s3_is_load;
  assign lsq_load_fwd_rob_tag_o = s3_rob_tag;
  assign lsq_load_fwd_addr_o    = s3_addr;

  // Forwarding merge helper
  function automatic [31:0] apply_fwd_merge(
    input logic [31:0] mem_data,
    input logic [31:0] fwd_data,
    input logic [3:0]  fwd_be
  );
    logic [31:0] out;
    begin
      out = mem_data;
      if (fwd_be[0]) out[7:0]   = fwd_data[7:0];
      if (fwd_be[1]) out[15:8]  = fwd_data[15:8];
      if (fwd_be[2]) out[23:16] = fwd_data[23:16];
      if (fwd_be[3]) out[31:24] = fwd_data[31:24];
      apply_fwd_merge = out;
    end
  endfunction

  always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
      s1_valid       <= 1'b0;
      s1_is_load     <= 1'b0;
      s1_is_store    <= 1'b0;
      s1_load_byte   <= 1'b0;
      s1_byte_offset <= 2'b0;
      s1_addr        <= '0;
      s1_dst_prf     <= '0;
      s1_rob_tag     <= '0;
      
      s2_valid       <= 1'b0;
      s2_is_load     <= 1'b0;
      s2_is_store    <= 1'b0;
      s2_load_byte   <= 1'b0;
      s2_byte_offset <= 2'b0;
      s2_addr        <= '0;
      s2_dst_prf     <= '0;
      s2_rob_tag     <= '0;

      s3_valid       <= 1'b0;
      s3_is_load     <= 1'b0;
      s3_is_store    <= 1'b0;
      s3_load_byte   <= 1'b0;
      s3_byte_offset <= 2'b0;
      s3_addr        <= '0;
      s3_dst_prf     <= '0;
      s3_rob_tag     <= '0;
      
      wb_valid_o     <= 1'b0;
      wb_data_o      <= '0;
      wb_dst_prf_o   <= '0;
      wb_rob_tag_o   <= '0;
    end else begin
      // Stage 0 -> 1
      s1_valid       <= (!flush_i) && valid_i && (is_load || is_store);
      s1_is_load     <= is_load;
      s1_is_store    <= is_store;
      s1_load_byte   <= load_byte;
      s1_byte_offset <= addr_gen[1:0];
      s1_addr        <= addr_gen;
      s1_dst_prf     <= pkt_i.dst_prf;
      s1_rob_tag     <= pkt_i.rob_tag;
      
      // Stage 1 -> 2
      s2_valid       <= s1_valid;
      s2_is_load     <= s1_is_load;
      s2_is_store    <= s1_is_store;
      s2_load_byte   <= s1_load_byte;
      s2_byte_offset <= s1_byte_offset;
      s2_addr        <= s1_addr;
      s2_dst_prf     <= s1_dst_prf;
      s2_rob_tag     <= s1_rob_tag;

      // Stage 2 -> 3
      s3_valid       <= s2_valid;
      s3_is_load     <= s2_is_load;
      s3_is_store    <= s2_is_store;
      s3_load_byte   <= s2_load_byte;
      s3_byte_offset <= s2_byte_offset;
      s3_addr        <= s2_addr;
      s3_dst_prf     <= s2_dst_prf;
      s3_rob_tag     <= s2_rob_tag;

      // Stage 3 -> Writeback (aligned to 2-cycle memory latency)
      wb_valid_o   <= s3_valid;
      wb_rob_tag_o <= s3_rob_tag;

      if (s3_valid && s3_is_load) begin
        logic [31:0] merged_word;
        
        // Merge memory data with LSQ forwarded data
        if (lsq_load_fwd_valid_i) begin
          merged_word = apply_fwd_merge(dmem_rdata_i, lsq_load_fwd_data_i, lsq_load_fwd_be_i);
        end else begin
          merged_word = dmem_rdata_i;
        end

        wb_dst_prf_o <= s3_dst_prf;

        // Extract byte/word based on load type
        if (s3_load_byte) begin
          case (s3_byte_offset)
            2'b00: wb_data_o <= {24'b0, merged_word[7:0]};
            2'b01: wb_data_o <= {24'b0, merged_word[15:8]};
            2'b10: wb_data_o <= {24'b0, merged_word[23:16]};
            2'b11: wb_data_o <= {24'b0, merged_word[31:24]};
          endcase
        end else begin
          wb_data_o <= merged_word;
        end
      end else if (s3_valid && s3_is_store) begin
        // Store completion (only signals ROB, no PRF write)
        wb_dst_prf_o <= '0;
        wb_data_o    <= '0;
      end else begin
        wb_dst_prf_o <= '0;
        wb_data_o    <= '0;
      end
    end
  end

endmodule
