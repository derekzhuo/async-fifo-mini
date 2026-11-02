// tb_fwft_vs_standard.v
// 标准读模式 vs FWFT(First-Word Fall-Through) 读模式对照实验
// 同一个参数化行为模型, 仅 FWFT 参数不同, 喂完全相同的激励:
//   复位 -> 写 A/B/C -> 空闲 2 拍 -> 连续 3 次读
// 逐拍对照 rd_data / valid / empty, 量化读延迟 (标准 1 周期, FWFT 0 周期)
// 另含边界用例: FWFT 中仅剩 1 个数据时 pop 与 write 同拍 (fall-through 旁路)
// 自包含, 无外部 rtl 依赖; iverilog 13.0 原生通过
`timescale 1ns/1ps

module fifo_model #(
  parameter FWFT  = 0,        // 0=标准读模式, 1=FWFT 模式
  parameter WIDTH = 8,
  parameter DEPTH = 8
) (
  input                  clk,
  input                  rst_n,
  input                  wr,       // 写请求 (两种模式语义相同)
  input                  pop,      // 标准模式: 读请求(取下一个); FWFT: 弹出已展示的队头
  input  [WIDTH-1:0]     wdata,
  output [WIDTH-1:0]     rd_data,
  output                 valid,    // rd_data 当前是否有效
  output                 empty,
  output                 full
);
  localparam AW = 3; // $clog2(DEPTH), DEPTH=8

  reg [WIDTH-1:0] mem [0:DEPTH-1];
  reg [AW-1:0]    wptr, rptr;
  reg [AW:0]      count;

  wire do_wr  = wr  && (count != DEPTH || (FWFT && pop && count != 0));
  wire do_pop = pop && (count != 0);

  // FWFT 队头旁路 mux 的选择条件:
  //  写空 FIFO (count==0): 写入数据同拍直送输出
  //  仅剩 1 项且同拍又读又写: 新数据 fall-through 到输出
  wire bypass = FWFT && do_wr && (count == 0 || (do_pop && count == 1));

  // 标准模式的输出寄存器 (address -> memory -> register 路径的最后一级)
  reg [WIDTH-1:0] q_reg;
  reg             q_valid;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wptr    <= 0; rptr <= 0; count <= 0;
      q_reg   <= 0; q_valid <= 0;
    end else begin
      if (do_wr) begin
        mem[wptr] <= wdata;
        wptr      <= wptr + 1'b1;
      end
      if (do_pop) begin
        if (!FWFT) begin
          q_reg   <= mem[rptr]; // 标准模式: 读请求后下一拍才锁存数据
          q_valid <= 1'b1;
        end
        rptr <= rptr + 1'b1;
      end else if (!FWFT) begin
        q_valid <= 1'b0;        // valid 只伴随读出数据存在一拍
      end
      count <= count + do_wr - do_pop;
    end
  end

  assign rd_data = FWFT ? (bypass ? wdata : mem[rptr]) : q_reg;
  assign valid   = FWFT ? ((count != 0) || (do_wr && count == 0)) : q_valid;
  assign empty   = FWFT ? ((count == 0) && !(do_wr && count == 0))
                        : (count == 0);
  assign full    = (count == DEPTH) && !(FWFT && pop && count != 0);
endmodule

module tb_fwft_vs_standard;
  reg clk = 0;
  always #5 clk = ~clk;

  reg        rst_n = 0;
  reg        wr = 0, pop_s = 0, pop_f = 0;
  reg [7:0]  wdata = 0;

  wire [7:0] d_s, d_f;
  wire       v_s, e_s, f_s, v_f, e_f, f_f;
  wire [3:0] c_s, c_f;

  fifo_model #(.FWFT(0)) u_std (
    .clk(clk), .rst_n(rst_n), .wr(wr), .pop(pop_s), .wdata(wdata),
    .rd_data(d_s), .valid(v_s), .empty(e_s), .full(f_s));
  fifo_model #(.FWFT(1)) u_fwft (
    .clk(clk), .rst_n(rst_n), .wr(wr), .pop(pop_f), .wdata(wdata),
    .rd_data(d_f), .valid(v_f), .empty(e_f), .full(f_f));
  assign c_s = u_std.count;
  assign c_f = u_fwft.count;

  // ---- 边界用例: 第三个实例, FWFT, 同拍 pop + write 且只剩 1 项 ----
  reg        wr2 = 0, pop2 = 0;
  reg [7:0]  wd2 = 0;
  wire [7:0] d2; wire v2, e2, f2; wire [3:0] c2;
  fifo_model #(.FWFT(1)) u_edge (
    .clk(clk), .rst_n(rst_n), .wr(wr2), .pop(pop2), .wdata(wd2),
    .rd_data(d2), .valid(v2), .empty(e2), .full(f2));
  assign c2 = u_edge.count;

  integer cyc = 0;
  integer err = 0;

  // 期望 (激励沿对齐后):
  //  标准模式: valid 仅 cyc8/9/10, 数据 A/B/C
  //  FWFT:     cyc3..7 队头 A 已展示, cyc8=B cyc9=C, cyc10 空
  task check;
    input integer c;
    begin
      if (c >= 8 && c <= 10) begin
        if (!v_s) begin
          $display("  [CHECK] cycle %0d: 标准模式 valid 应为 1", c); err=err+1; end
        if (d_s !== (8'h41 + c - 8)) begin
          $display("  [CHECK] cycle %0d: 标准 rd_data=%c 期望 %c",
                   c, d_s, 8'h41+c-8); err=err+1; end
      end else if (v_s) begin
        $display("  [CHECK] cycle %0d: 标准模式 valid 不应拉起", c); err=err+1;
      end
      if (c >= 3 && c <= 9 && !v_f) begin
        $display("  [CHECK] cycle %0d: FWFT valid 应为 1", c); err=err+1; end
      if (c >= 3 && c <= 7 && d_f !== "A") begin
        $display("  [CHECK] cycle %0d: FWFT rd_data=%c 期望 A", c, d_f); err=err+1; end
      if (c == 8 && d_f !== "B") begin
        $display("  [CHECK] cycle 8: FWFT rd_data=%c 期望 B", d_f); err=err+1; end
      if (c == 9 && d_f !== "C") begin
        $display("  [CHECK] cycle 9: FWFT rd_data=%c 期望 C", d_f); err=err+1; end
      if (c == 10 && !e_f) begin
        $display("  [CHECK] cycle 10: FWFT 应已 empty"); err=err+1; end
    end
  endtask

  initial begin
    $display("==================================================================");
    $display(" FWFT vs 标准读模式对照 (depth=8, 单一时钟 10ns, 行为模型)");
    $display(" 标准: pop 后下一拍 rd_data/valid    FWFT: 非空即展示, pop=弹出");
    $display(" cyc | wr wdata pop | STD empty rd_data valid occ | FWFT empty rd_data valid occ");
  end

  // 激励在 negedge 给出, 保证下一 posedge 稳定采样
  initial begin
    @(negedge clk) rst_n = 1;          // cyc1 沿前释放复位
    @(negedge clk) begin wr=1; wdata="A"; end   // cyc2 写 A
    @(negedge clk) wdata = "B";                  // cyc3 写 B
    @(negedge clk) wdata = "C";                  // cyc4 写 C
    @(negedge clk) begin wr=0; wdata=0; end     // cyc5 空闲
    @(negedge clk);                              // cyc6 空闲
    @(negedge clk) begin pop_s=1; pop_f=1; end  // cyc7 读
    @(negedge clk);                              // cyc8 读
    @(negedge clk);                              // cyc9 读
    @(negedge clk) begin pop_s=0; pop_f=0; end  // cyc10 空闲
    @(negedge clk);                              // cyc11
    $display("------------------------------------------------------------------");
    $display("[LATENCY] 标准模式: pop@cyc8 沿采样 -> 沿后 rd_data=A/valid=1, 下游 cyc9 沿才采到, 读延迟 = 1 周期");
    $display("[LATENCY] FWFT:      rd_data=A 在写入当拍 cyc3 即展示, 无需 pop, 读延迟 = 0 周期");
    $display("------------------------------------------------------------------");
    edge_case;
    $display("------------------------------------------------------------------");
    if (err == 0) $display("SUMMARY 全部逐拍核对一致, CHECK 失败 = 0");
    else          $display("SUMMARY CHECK 失败 = %0d", err);
    $finish;
  end

  // posedge 后采样打印
  always @(posedge clk) begin
    cyc = cyc + 1;
    #1 if (cyc >= 1 && cyc <= 10) begin
      check(cyc);
      $display(" %3d |  %b   %c   %b/%b |  STD  %b     %c     %b   %2d | FWFT  %b     %c     %b   %2d",
        cyc, wr, (wr ? wdata : "-"), pop_s, pop_f,
        e_s, (v_s ? d_s : "-"), v_s, c_s,
        e_f, (v_f ? d_f : "-"), v_f, c_f);
    end
  end

  integer eerr = 0;
  task edge_case;
    begin
      $display("[2] 边界用例 FWFT: FIFO 仅剩 1 项 D, pop 与 write(E) 同拍");
      // 写 1 个 D
      @(negedge clk) begin wr2=1; wd2="D"; end
      @(posedge clk) #1;
      $display("  写入 D 后:      rd_data=%c valid=%b empty=%b occ=%0d (未发 pop, 队头已展示)",
               d2, v2, e2, c2);
      if (d2 !== "D" || !v2 || c2 != 1) begin
        $display("  [CHECK] D 应直接展示在输出且 occ=1"); eerr=eerr+1; end
      // 空闲一拍保持
      @(negedge clk) wr2=0;
      @(posedge clk) #1;
      $display("  空闲保持一拍:   rd_data=%c valid=%b (FWFT 输出保持队头)", d2, v2);
      // 同拍 pop + write E
      @(negedge clk) begin pop2=1; wr2=1; wd2="E"; end
      @(posedge clk) #1;
      $display("  pop+write 同拍: rd_data=%c valid=%b empty=%b occ=%0d (新数据 E fall-through 到输出)",
               d2, v2, e2, c2);
      if (d2 !== "E" || c2 !== 1) begin
        $display("  [CHECK] 期望 rd_data=E occ=1 (旁路), 实际 %c occ=%0d",
                 d2, c2); eerr=eerr+1; end
      // 再 pop 一次取空
      @(negedge clk) begin pop2=1; wr2=0; end
      @(posedge clk) #1;
      $display("  再 pop E 之后:  rd_data=%c valid=%b empty=%b occ=%0d",
               (v2 ? d2 : "-"), v2, e2, c2);
      if (!e2 || c2 !== 0) begin
        $display("  [CHECK] 期望 empty=1 occ=0"); eerr=eerr+1; end
      if (eerr == 0)
        $display("SUMMARY 边界用例: 同拍 pop+write 旁路正确, D 先展示后被弹出, CHECK 失败 = 0");
      else
        $display("SUMMARY 边界用例 CHECK 失败 = %0d", eerr);
      err = err + eerr;
    end
  endtask
endmodule
