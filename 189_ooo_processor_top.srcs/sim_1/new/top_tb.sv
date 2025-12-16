`timescale 1ns / 1ps

module top_tb;

  // ============================================================
  // Parameters
  // ============================================================
  parameter CLK_PERIOD = 10;  // 100MHz
  parameter SIM_CYCLES = 1000;

  // ============================================================
  // Signals
  // ============================================================
  logic        clk;
  logic        reset;
  logic [31:0] pc_out;
  logic        commit_valid;

  // ============================================================
  // DUT Instantiation
  // ============================================================
  top #(
    .PHYS_REGS   (128),
    .ROB_ENTRIES (16),
    .WORDS       (512),
    .MEMFILE     ("25instMem-r.mem")
  ) u_dut (
    .clk            (clk),
    .reset          (reset),
    .pc_out         (pc_out),
    .commit_valid_o (commit_valid)
  );

  // ============================================================
  // Clock Generation
  // ============================================================
  initial clk = 0;
  always #(CLK_PERIOD/2) clk = ~clk;

  // ============================================================
  // Commit Counter & Cycle Counter
  // ============================================================
  int commit_count = 0;
  int cycle_count = 0;
  int last_commit_cycle = 0;

  // Branch prediction / recovery counters
  int fetch_count = 0;
  int bp_hit_count = 0;
  int bp_taken_count = 0;
  int bp_update_count = 0;
  int br_mispredict_count = 0;
  
  always_ff @(posedge clk) begin
    if (reset) begin
      commit_count <= 0;
      cycle_count <= 0;
      last_commit_cycle <= 0;

      fetch_count <= 0;
      bp_hit_count <= 0;
      bp_taken_count <= 0;
      bp_update_count <= 0;
      br_mispredict_count <= 0;
    end else begin
      cycle_count <= cycle_count + 1;
      if (commit_valid) begin
        commit_count <= commit_count + 1;
        last_commit_cycle <= cycle_count + 1;  // record cycle of last commit
        $display("COMMIT #%0d @cycle %0d", commit_count + 1, cycle_count + 1);
      end

      // Count fetch-side predictor activity only when fetch is producing a valid instruction
      if (u_dut.valid_fetch) begin
        fetch_count <= fetch_count + 1;
        if (u_dut.bp_pred_hit_fetch)  bp_hit_count   <= bp_hit_count + 1;
        if (u_dut.bp_pred_taken_fetch) bp_taken_count <= bp_taken_count + 1;
      end

      // Count predictor updates (one per resolved branch/jump in branch_unit)
      if (u_dut.bp_update_valid) begin
        bp_update_count <= bp_update_count + 1;
      end

      // Count mispredict recovery pulses
      if (u_dut.branch_mispredict) begin
        br_mispredict_count <= br_mispredict_count + 1;
      end
    end
  end

  // ============================================================
  // Detect when all instructions have committed
  // ============================================================
  logic fetch_stopped;
  logic rob_empty;
  // fetch_module asserts valid_in=0 when it sees the all-zero instruction (program_end)
  // Using the module output avoids relying on transient instr values during redirection.
  assign fetch_stopped = (u_dut.valid_fetch == 1'b0);
  // ROB uses one-slot-empty scheme; empty when head == tail
  assign rob_empty = (u_dut.u_dispatch.u_rob.head == u_dut.u_dispatch.u_rob.tail);
  
  int stable_cycles;
  always_ff @(posedge clk or posedge reset) begin
    if (reset) begin
      stable_cycles <= 0;
    end else if (fetch_stopped && rob_empty && !commit_valid) begin
      stable_cycles <= stable_cycles + 1;
    end else begin
      stable_cycles <= 0;
    end
  end

  // ============================================================
  // Register Value Access (via hierarchical path)
  // ============================================================
  logic [6:0]  a0_prf, a1_prf;
  logic [31:0] a0_val, a1_val;

  assign a0_prf = u_dut.u_rename.u_map_table.map[10];
  assign a1_prf = u_dut.u_rename.u_map_table.map[11];
  assign a0_val = u_dut.u_dispatch.u_prf.rf[a0_prf];
  assign a1_val = u_dut.u_dispatch.u_prf.rf[a1_prf];

  // ============================================================
  // Test Sequence
  // ============================================================
  initial begin
    bit timed_out;
    timed_out = 0;
    reset = 1;
    repeat(5) @(posedge clk);
    reset = 0;
    
    // Wait until fetch stops and pipeline is drained (no commits for 30 cycles)
    fork
      begin
        wait(stable_cycles >= 30);
      end
      begin
        repeat(SIM_CYCLES) @(posedge clk);
        timed_out = 1;
        $display("WARNING: Simulation timeout!");
      end
    join_any
    disable fork;
    
    // Report results
    $display("========================================");
    $display("Simulation Complete");
    $display("Total commits: %0d", commit_count);
    $display("Total cycles:  %0d (to last commit)", last_commit_cycle);
    $display("IPC:           %.3f", real'(commit_count) / real'(last_commit_cycle));
    $display("Final PC: 0x%08h", pc_out);
    $display("Register Values:");
    $display("  a0 (x10) = %0d", a0_val);
    $display("  a1 (x11) = %0d", a1_val);
    $display("========================================");
    
    $finish;
  end

  // ============================================================
  // Debug Monitors
  // ============================================================

endmodule
