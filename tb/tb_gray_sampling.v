// tb_gray_sampling.v
// 格雷码跨时钟域必然性采样实验
//
// 同一个递增计数器（0->7->0）分别以二进制和格雷码两组总线送出，
// 用两级触发器在目的时钟域采样。为了把硅片上真实存在的「位间偏斜」
// （不同 bit 走线延迟不同）带进仿真，源总线每位加不同的传播延迟：
//   bit0 延迟 4ns、bit1 延迟 5ns、bit2 延迟 6ns；
// 目的时钟沿刻意落在更新后 +4.5ns，即偏斜窗口内部。
//
// 判定口径：采样值若既不是旧计数值也不是新计数值，记 ILLEGAL
// （语义上意味着 FIFO 满空比较拿到了一个谁也没发送过的指针）。
`timescale 100ps/100ps
module tb_gray_sampling;

  // 时间单位 100ps：半周期 50 = 5ns，源时钟周期 10ns
  reg clk_a = 1'b0;
  reg clk_b = 1'b0;

  always #50 clk_a = ~clk_a;
  // 目的时钟同周期、上升沿比源更新沿晚 4.5ns（95 单位 = 9.5ns）
  initial begin
    #95 clk_b = 1'b1;       // 首次上升沿：源更新后 +4.5ns
    forever #50 clk_b = ~clk_b;
  end

  // ---- 源域：3-bit 递增计数器 ----
  reg [2:0] cnt = 3'd0;
  reg [2:0] prev_cnt = 3'd0;
  always @(posedge clk_a) begin
    prev_cnt <= cnt;
    cnt      <= cnt + 3'd1;
  end

  function [2:0] bin2gray(input [2:0] b);
    bin2gray = b ^ (b >> 1);
  endfunction

  wire [2:0] gray = bin2gray(cnt);
  wire [2:0] prev_gray = bin2gray(prev_cnt);

  // ---- 位间偏斜模型：每位到达目的端的时间不同 ----
  reg [2:0] bin_skew, gray_skew;
  integer i;
  always @(*) begin
    for (i = 0; i < 3; i = i + 1) begin
      bin_skew[i]  <= #(40 + i*10) cnt[i];   // 4ns / 5ns / 6ns
      gray_skew[i] <= #(40 + i*10) gray[i];
    end
  end

  // ---- 目的域：两级触发器同步链 ----
  reg [2:0] bin_s1 = 3'd0, bin_s2 = 3'd0;
  reg [2:0] gry_s1 = 3'd0, gry_s2 = 3'd0;

  // 给采样值打上「本次跳变旧值/新值」的标签，随两级链一起流水
  reg [2:0] bo1 = 0, bn1 = 0, bo2 = 0, bn2 = 0;
  reg [2:0] go1 = 0, gn1 = 0, go2 = 0, gn2 = 0;

  always @(posedge clk_b) begin
    bin_s1 <= bin_skew; bin_s2 <= bin_s1;
    gry_s1 <= gray_skew; gry_s2 <= gry_s1;
    bo1 <= prev_cnt; bn1 <= cnt; bo2 <= bo1; bn2 <= bn1;
    go1 <= prev_gray; gn1 <= gray; go2 <= go1; gn2 <= gn1;
  end

  integer bin_illegal = 0;
  integer gry_illegal = 0;
  integer samples = 0;

  // 两级链输出稳定后（第二次 b 沿起）逐拍核对
  always @(posedge clk_b) begin
    if (samples >= 2 && samples <= 9) begin
      $display("STEP %0d->%0d t=%0t(0.1ns) : bin_s2=%b(%0d) %0s | gray_s2=%b(%0d) %0s",
               bo2, bn2, $time,
               bin_s2, bin_s2,
               (bin_s2 === bo2 || bin_s2 === bn2) ? "LEGAL" : "ILLEGAL",
               gry_s2, gry_s2,
               (gry_s2 === go2 || gry_s2 === gn2) ? "LEGAL" : "ILLEGAL");
      if (bin_s2 !== bo2 && bin_s2 !== bn2) bin_illegal = bin_illegal + 1;
      if (gry_s2 !== go2 && gry_s2 !== gn2) gry_illegal = gry_illegal + 1;
    end
    samples = samples + 1;
  end

  initial begin
    #1050;
    $display("EVIDENCE samples=8 bin_illegal=%0d gray_illegal=%0d",
             bin_illegal, gry_illegal);
    if (bin_illegal > 0 && gry_illegal == 0)
      $display("PASS tb_gray_sampling: binary caught illegal intermediates, gray never did");
    else
      $display("FAIL tb_gray_sampling");
    $finish;
  end

endmodule
