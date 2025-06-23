`define PRINT_OUTPUTS

module tb_rename;
  //--------------------------------------------------------------------
  // ❶ DUT connections
  //--------------------------------------------------------------------
  logic clk, reset;

  dinstr_t    dinstr;
  p_reg_t     p_commit;
  rinstr_t    rinstr;
  br_result_t br_result;
  logic       rn_full;

  rename RENAME (
    .clk        (clk),
    .rst_ni     (reset),
    .br_result_i(br_result),
    .p_commit_i (p_commit),
    .dinstr_i   (dinstr),
    .rinstr_o   (rinstr),
    .rn_full_o  (rn_full)
  );

  //--------------------------------------------------------------------
  // ❷ clock - 10-unit period
  //--------------------------------------------------------------------
  initial begin
    clk = 1'b1;
    forever #5 clk = ~clk;
  end

  //--------------------------------------------------------------------
  // ❸ reference / scoreboard data
  //--------------------------------------------------------------------
  logic [5:0] rename_map [31:0];
  logic       ready_map  [63:0];
  int         ref_counter[63:0];

  rinstr_t instrs[$];
  rinstr_t committed_instr;

  int commit_timer;  // only driven in always_ff

  //--------------------------------------------------------------------
  // ❹ one-time init (does NOT touch commit_timer / p_commit)
  //--------------------------------------------------------------------
  initial begin
    reset     = 0;
    br_result = '0;
    dinstr    = '0;

    for (int i=0; i<32; i++) rename_map[i] = i[5:0];
    for (int i=0; i<64; i++) ready_map [i] = 1;
    for (int i=0; i<64; i++) ref_counter[i] = 0;

    #50 reset = 1;
  end

  //--------------------------------------------------------------------
  // ❺ commit producer - single driver
  //--------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!reset) begin
      commit_timer <= 5;
      p_commit     <= '0;
    end else begin
      if (commit_timer == 0) begin
        p_commit <= '0;  // default LOW
        if (instrs.size() != 0) begin
          committed_instr = instrs.pop_front();
          if (committed_instr.rd.valid) begin
            p_commit <= '{valid:1, idx:committed_instr.rd.idx, ready:0};
            ready_map[committed_instr.rd.idx] <= 1;
            `ifdef PRINT_OUTPUTS
              $display("%0t  commit p%0d", $time, committed_instr.rd.idx);
            `endif
          end
          if (committed_instr.rs1.valid) ref_counter[committed_instr.rs1.idx]--;
          if (committed_instr.rs2.valid) ref_counter[committed_instr.rs2.idx]--;
        end
        commit_timer <= $urandom_range(1,3);
      end else begin
        commit_timer <= commit_timer - 1;
        p_commit     <= '0;
      end
    end
  end

  //--------------------------------------------------------------------
  // ❻ helper: apply one instruction
  //--------------------------------------------------------------------
  task automatic apply_instr(input dinstr_t d, input br_result_t b);
    @(negedge clk);
    dinstr    = d;
    br_result = b;
    #1 check_output();
    @(negedge clk);
    dinstr    = '0;
    br_result = '0;
  endtask

  //--------------------------------------------------------------------
  // ❼ MANUAL stimulus sequence
  //--------------------------------------------------------------------
  initial begin
    @(posedge reset);

    apply_instr('{valid:1, rd:'{valid:1, idx:1}, rs1:'{valid:1, idx:2}, rs2:'{valid:1, idx:3}, is_branch:0}, '{valid:0, hit:0});
    apply_instr('{valid:1, rd:'{valid:1, idx:1}, rs1:'{valid:1, idx:1}, rs2:'{valid:0, idx:3}, is_branch:0}, '{valid:0, hit:0});
    apply_instr('{valid:1, rd:'{valid:1, idx:5}, rs1:'{valid:1, idx:2}, rs2:'{valid:1, idx:6}, is_branch:0}, '{valid:0, hit:0});
    apply_instr('{valid:1, rd:'{valid:1, idx:3}, rs1:'{valid:1, idx:5}, rs2:'{valid:1, idx:2}, is_branch:0}, '{valid:0, hit:0});
    apply_instr('{valid:1, rd:'{valid:0, idx:1}, rs1:'{valid:1, idx:1}, rs2:'{valid:1, idx:5}, is_branch:1}, '{valid:0, hit:0});
    apply_instr('{valid:1, rd:'{valid:1, idx:1}, rs1:'{valid:0, idx:2}, rs2:'{valid:0, idx:3}, is_branch:0}, '{valid:0, hit:0});
    apply_instr('{valid:1, rd:'{valid:1, idx:4}, rs1:'{valid:1, idx:0}, rs2:'{valid:1, idx:5}, is_branch:0}, '{valid:0, hit:0});
    apply_instr('{valid:1, rd:'{valid:1, idx:5}, rs1:'{valid:1, idx:8}, rs2:'{valid:1, idx:1}, is_branch:0}, '{valid:0, hit:0});
    apply_instr('{valid:1, rd:'{valid:1, idx:7}, rs1:'{valid:1, idx:5}, rs2:'{valid:1, idx:1}, is_branch:0}, '{valid:1, hit:0});
    apply_instr('{valid:1, rd:'{valid:1, idx:8}, rs1:'{valid:1, idx:5}, rs2:'{valid:1, idx:7}, is_branch:0}, '{valid:0, hit:0});

    repeat (30) @(posedge clk);
    $display("\nSimulation DONE");
    $finish;
  end

  //--------------------------------------------------------------------
  // ❽ check_output & print_results
  //--------------------------------------------------------------------
  task check_output();
    assert(dinstr.valid == rinstr.valid) else $error("rinstr.valid mismatch");

    if (rinstr.valid) begin
      `ifdef PRINT_OUTPUTS
        print_results();
      `endif

      assert(dinstr.rd.valid  == rinstr.rd.valid ) else $error("rd.valid mismatch");
      assert(dinstr.rs1.valid == rinstr.rs1.valid) else $error("rs1.valid mismatch");
      assert(dinstr.rs2.valid == rinstr.rs2.valid) else $error("rs2.valid mismatch");

      if (rinstr.rs1.valid) begin
        assert(rinstr.rs1.idx == rename_map[dinstr.rs1.idx]) else $error("rs1.idx wrong");
        assert(rinstr.rs1.ready == ready_map[rinstr.rs1.idx]) else $error("rs1.ready wrong");
        ref_counter[rinstr.rs1.idx]++;
      end
      if (rinstr.rs2.valid) begin
        assert(rinstr.rs2.idx == rename_map[dinstr.rs2.idx]) else $error("rs2.idx wrong");
        assert(rinstr.rs2.ready == ready_map[rinstr.rs2.idx]) else $error("rs2.ready wrong");
        ref_counter[rinstr.rs2.idx]++;
      end
      if (rinstr.rd.valid) begin
        assert(ready_map[rinstr.rd.idx]==1) else $error("rd busy reg");
        rename_map[dinstr.rd.idx] = rinstr.rd.idx;
        ready_map [rinstr.rd.idx] = 0;
        assert(ref_counter[rinstr.rd.idx]==0) else $error("rd dep unresolved");
        ref_counter[rinstr.rd.idx] = 0;
      end
      instrs.push_back(rinstr);
    end
  endtask

  task print_results();
    string msg;
    msg = $sformatf("dinstr:{rd:%s, rs1:%s, rs2:%s} -> rinstr:{rd:%s, rs1:{%s,%s}, rs2:{%s,%s}}",
                     dinstr.rd.valid  ? itoa(int'(dinstr.rd.idx))  : "-",
                     dinstr.rs1.valid ? itoa(int'(dinstr.rs1.idx)) : "-",
                     dinstr.rs2.valid ? itoa(int'(dinstr.rs2.idx)) : "-",
                     rinstr.rd.valid  ? itoa(int'(rinstr.rd.idx))  : "-",
                     rinstr.rs1.valid ? itoa(int'(rinstr.rs1.idx)) : "-",
                     rinstr.rs1.valid ? (rinstr.rs1.ready ? "YES" : "NO") : "-",
                     rinstr.rs2.valid ? itoa(int'(rinstr.rs2.idx)) : "-",
                     rinstr.rs2.valid ? (rinstr.rs2.ready ? "YES" : "NO") : "-");
    $display("%s", msg);
  endtask

  function automatic string itoa(int val);
    string s; s.itoa(val); return s;
  endfunction
endmodule
