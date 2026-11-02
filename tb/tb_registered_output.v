// tb_registered_output.v
// FIFO 输出寄存取舍实验（行为对照，依赖 rtl/fwft_fifo.v）
// 三个变体同激励：
//   D  直出 FWFT（OUT_REG=0）：读延迟 0，ready 组合反传回 pop
//   K  FWFT + skid 输出寄存器（OUT_REG=1）：读延迟 1，反压时输出保持、吸收 1 beat
//   N  FWFT + 简单打拍（不反传 ready 的错误实现）：反压时寄存器被覆盖，丢数据
// 激励（沿后驱动，模拟寄存器输出的写者/读者）：
//   复位 2 拍后背靠背写 A/B/C/D -> 空闲 2 拍 -> ready=1 取 1 拍
//   -> ready=0 两拍（反压窗口）-> ready 恢复并排空；逐拍打印，末尾 CHECK。
`timescale 1ns/1ps
module tb_registered_output;

  reg clk = 0;
  reg rst = 1;
  reg wr = 0;
  reg [7:0] wdata = 0;
  reg dst_ready = 0;

  wire [7:0] d_d, k_d, n_d;
  wire d_v, k_v, n_v;
  wire d_pop, k_pop, n_pop, k_buf;

  fwft_fifo #(.OUT_REG(0)) D (
    .clk(clk), .rst(rst), .wr(wr), .wdata(wdata),
    .dst_ready(dst_ready), .o_data(d_d), .o_valid(d_v),
    .pop_dbg(d_pop), .buf_v_dbg());
  fwft_fifo #(.OUT_REG(1)) K (
    .clk(clk), .rst(rst), .wr(wr), .wdata(wdata),
    .dst_ready(dst_ready), .o_data(k_d), .o_valid(k_v),
    .pop_dbg(k_pop), .buf_v_dbg(k_buf));
  fwft_fifo_naive N (
    .clk(clk), .rst(rst), .wr(wr), .wdata(wdata),
    .dst_ready(dst_ready), .o_data(n_d), .o_valid(n_v),
    .pop_dbg(n_pop));

  always #5 clk = ~clk;

  integer cyc = 0;
  integer d_first = -1, k_first = -1, n_first = -1;
  integer d_pop_cnt = 0, k_pop_cnt = 0, n_pop_cnt = 0;
  integer d_got = 0, k_got = 0, n_got = 0;
  integer k_pops_in_stall = 0, d_pops_in_stall = 0;
  reg [7:0] d_seq [0:7];
  reg [7:0] k_seq [0:7];
  reg [7:0] n_seq [0:7];
  reg [7:0] expq [0:3];
  integer i, f, fails;

  // 沿后 2ns 驱动输入（寄存器化的写者/读者），一拍一个编号
  task drive(input integer c, input wrv, input [7:0] wd, input rdy);
    begin
      @(posedge clk);
      #2 cyc = c; rst = (c <= 2); wr = wrv; wdata = wd; dst_ready = rdy;
    end
  endtask

  initial begin
    expq[0] = "A"; expq[1] = "B"; expq[2] = "C"; expq[3] = "D";
    $display("==================================================================");
    $display(" FIFO 输出寄存取舍: D=直出FWFT  K=FWFT+skid寄存  N=简单打拍(反面)");
    $display(" 激励: 复位2拍, 写A/B/C/D, idle2, ready=1取1拍, ready=0停2拍, 再排空");
    $display(" cyc | wr wdata rdy | D: v data pop occ | K: v data pop buf occ | N: v data pop occ");

    drive(1, 0, 8'h2d, 0);
    drive(2, 0, 8'h2d, 0);
    for (i = 0; i < 4; i = i + 1) drive(3 + i, 1, expq[i], 0);
    drive(7, 0, 8'h2d, 0);
    drive(8, 0, 8'h2d, 0);
    drive(9, 0, 8'h2d, 1);   // 取走 1 拍
    drive(10, 0, 8'h2d, 0);  // 反压窗口
    drive(11, 0, 8'h2d, 0);
    for (i = 0; i < 5; i = i + 1) drive(12 + i, 0, 8'h2d, 1);
    drive(17, 0, 8'h2d, 1);
    #3;

    fails = 0;
    $display("------------------------------------------------------------------");
    $display("SUMMARY 行为对照:");
    $display("  首个 o_valid 出现拍: D=cyc%0d (期望3, 读延迟0)  K=cyc%0d (期望4, 读延迟1)  N=cyc%0d (期望4)",
             d_first, k_first, n_first);
    $display("  内核 pop 总数:       D=%0d  K=%0d  N=%0d (N 无视 ready 强行弹空 FIFO)",
             d_pop_cnt, k_pop_cnt, n_pop_cnt);
    $display("  下游实际收到 beat:   D=%0d  K=%0d  N=%0d", d_got, k_got, n_got);
    $display("  反压窗口(cyc10-11)内内核 pop: D=%0d (ready 组合顶住)  K=%0d (skid 吸收1拍)",
             d_pops_in_stall, k_pops_in_stall);
    if (d_first !== 3) begin $display("CHECK FAIL: D 首拍应在 cyc3"); fails=fails+1; end
    if (k_first !== 4) begin $display("CHECK FAIL: K 首拍应在 cyc4"); fails=fails+1; end
    if (n_first !== 4) begin $display("CHECK FAIL: N 首拍应在 cyc4"); fails=fails+1; end
    if (d_got !== 4 || k_got !== 4) begin
      $display("CHECK FAIL: D/K 应收齐 4 beat (D=%0d K=%0d)", d_got, k_got); fails=fails+1;
    end
    if (n_got !== 0) begin
      $display("CHECK FAIL: N 为反面实现, 本激励下应 1 beat 都没交到, 实际 %0d", n_got); fails=fails+1;
    end
    for (f = 0; f < 4; f = f + 1) begin
      if (f < d_got && d_seq[f] !== expq[f]) begin
        $display("CHECK FAIL: D 序列第 %0d 项=%s 期望 %s", f, d_seq[f], expq[f]); fails=fails+1;
      end
      if (f < k_got && k_seq[f] !== expq[f]) begin
        $display("CHECK FAIL: K 序列第 %0d 项=%s 期望 %s", f, k_seq[f], expq[f]); fails=fails+1;
      end
    end
    if (k_pops_in_stall !== 1) begin
      $display("CHECK FAIL: 反压窗口 K 应吸收 1 beat, 实际 pop=%0d", k_pops_in_stall); fails=fails+1;
    end
    if (d_pops_in_stall !== 0) begin
      $display("CHECK FAIL: 反压窗口 D 不应弹出, 实际 pop=%0d", d_pops_in_stall); fails=fails+1;
    end
    $display(" 序列: D=%s %s %s %s | K=%s %s %s %s | N 收到 %0d beat (A/B/C/D 均被覆盖或错过)",
             d_seq[0], d_seq[1], d_seq[2], d_seq[3],
             k_seq[0], k_seq[1], k_seq[2], k_seq[3], n_got);
    $display("SUMMARY: CHECK 失败 = %0d (N 的丢数是预期复现, 不计失败)", fails);
    $finish;
  end

  // 沿后 4ns 采样（输入已稳定，寄存器已更新）
  always @(posedge clk) #4 begin
    if (cyc >= 1 && cyc <= 17) begin
      if (d_v && d_first < 0) d_first = cyc;
      if (k_v && k_first < 0) k_first = cyc;
      if (n_v && n_first < 0) n_first = cyc;
      if (d_pop) d_pop_cnt = d_pop_cnt + 1;
      if (k_pop) k_pop_cnt = k_pop_cnt + 1;
      if (n_pop) n_pop_cnt = n_pop_cnt + 1;
      if ((cyc == 10 || cyc == 11) && k_pop) k_pops_in_stall = k_pops_in_stall + 1;
      if ((cyc == 10 || cyc == 11) && d_pop) d_pops_in_stall = d_pops_in_stall + 1;
      if (d_v && dst_ready) begin d_seq[d_got] = d_d; d_got = d_got + 1; end
      if (k_v && dst_ready) begin k_seq[k_got] = k_d; k_got = k_got + 1; end
      if (n_v && dst_ready) begin n_seq[n_got] = n_d; n_got = n_got + 1; end
      $display("  %2d |  %0d   %s   %0d |    %0d   %s   %0d  %2d |    %0d   %s   %0d   %0d  %2d |    %0d   %s   %0d  %2d",
               cyc, wr, (wr ? wdata : 8'h2d), dst_ready,
               d_v, (d_v ? d_d : 8'h2d), d_pop, D.count,
               k_v, (k_v ? k_d : 8'h2d), k_pop, k_buf, K.count,
               n_v, (n_v ? n_d : 8'h2d), n_pop, N.count);
    end
  end

endmodule
