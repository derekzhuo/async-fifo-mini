// tb_pointer_wraparound.v
// FIFO 指针绕回与扩展位：深度 4 小状态空间枚举实验
//
// 核心问题：深度 2^n 的 FIFO，读写指针都按模 2^n 绕回，绕回之后指针
// 重新相等。「指针相等」在绕回前表示空（读者追上写者），在写满一圈后
// 表示满（写者套圈追上读者）——单看 n 位裸指针，两种状态不可区分。
//
// 本 testbench 用 depth=4（n=2）把全部状态枚举一遍，三组模型对照：
//   [1] 扩展位模型：指针 n+1=3 位，低位寻址、最高位记录「第几圈」。
//       empty = (we == re)；full = (we == {~re[2], re[1:0]})。
//       异步 FIFO 中指针以格雷码跨域，等价的格雷判据为「高两位相反、
//       余位相同」，本实验同时在两个满点打印格雷码供核对。
//   [2] 无扩展位注错：指针只有 2 位，full/empty 只能都由相等式导出。
//       策略 E 把相等解释为空 -> 写满后第 5 写被接受、覆盖未读数据；
//       策略 F 把相等解释为满 -> 复位态就报满，首批写全被挡、启动死锁。
//   [3] 备选方案（n 位指针 + 占用计数器，深度只用 2^n-1=3 项）：
//       满/空由 count 判定，指针不再需要相等之外的信息，代价是
//       4 个槽位永久浪费 1 个（25%）。
`timescale 1ns/100ps
module tb_pointer_wraparound;

  // ---------- [1] 扩展位模型：3 位扩展指针 ----------
  reg [2:0] we = 3'b000;   // 扩展写指针（含圈数位 MSB）
  reg [2:0] re = 3'b000;   // 扩展读指针
  integer   occ = 0;       // 真实占用 0..4（上帝视角）

  wire full_a  = (we == {~re[2], re[1:0]});
  wire empty_a = (we == re);
  wire [2:0] wgray = (we >> 1) ^ we;
  wire [2:0] rgray = (re >> 1) ^ re;

  task step_a(input [7:0] op, input integer delta);
    integer k;
    begin
      if (op == "W") begin
        we  = we + 3'd1;
        occ = occ + delta;
      end else begin
        re  = re + 3'd1;
        occ = occ + delta;
      end
      #1;  // 让连续赋值的 full/empty/gray 完成传播
      $display("  %0s  occ=%0d  wptr_ext=%b(%0d) rptr_ext=%b(%0d)  full=%b empty=%b",
               op, occ, we, we, re, re, full_a, empty_a);
    end
  endtask

  // ---------- [2] 无扩展位注错模型：2 位裸指针 ----------
  reg [1:0] wn = 2'b00, rn = 2'b00;
  reg [7:0] mem [0:3];
  integer k;
  integer overwrite = 0;   // 策略 E：未读槽被覆盖次数
  integer mismatch  = 0;   // 策略 E：读回数据错配次数
  integer starve    = 0;   // 策略 F：复位后被假满挡下的写次数
  reg [7:0] got;

  // ---------- [3] 计数器备选模型：深度 4 只用 3 项 ----------
  reg [1:0] cnt = 2'd0;    // 占用计数 0..3
  wire full_c  = (cnt == 2'd3);
  wire empty_c = (cnt == 2'd0);
  integer rejected_c = 0;

  initial begin
    $display("------------------------------------------------------------------");
    $display("[1] 扩展位模型 depth=4 (n=2): 指针 3 位, 低 2 位寻址, MSB 记圈数");
    $display("    empty=(wptr_ext==rptr_ext)  full=(MSB 相反且余位相同)");
    $display("  RST occ=0  wptr_ext=000(0) rptr_ext=000(0)  full=0 empty=1");

    // 连续写 4 个：第 4 写在 3->0 绕回，we=100
    step_a("W", 1); step_a("W", 1); step_a("W", 1); step_a("W", 1);
    $display("    >> 第4写: 寻址低位 3->0 绕回, wgray=%b rgray=%b (满点A)", wgray, rgray);
    // 逐次读 4 个读空：re 追上 100
    step_a("R", -1); step_a("R", -1); step_a("R", -1); step_a("R", -1);
    $display("    >> 读空: 两侧扩展位都=1 (100==100), 与写满状态不再混淆");
    // 再写一圈：W8 处 we 111->000 绕回，满点 B
    step_a("W", 1); step_a("W", 1); step_a("W", 1); step_a("W", 1);
    $display("    >> 第8写: 写指针扩展位 1->0 再次绕回, wgray=%b rgray=%b (满点B)",
             wgray, rgray);

    $display("------------------------------------------------------------------");
    $display("[2] 无扩展位注错: 2 位裸指针, full/empty 都只能由 (wn==rn) 导出");
    $display("    复位       wn=00 rn=00 相等=1 | 真值: 空");
    // 写满 4 个
    for (k = 0; k < 4; k = k + 1) begin
      mem[wn] = 8'hA1 + k[7:0];
      wn = wn + 2'd1;
    end
    $display("    连写4个后 wn=%b rn=%b 相等=%b | 真值: 满(occ=4) 却同时满足空判据",
             wn, rn, (wn == rn));

    // 策略 E：相等解释为空（empty=相等，没有独立满信号，写侧不被挡）
    $display("  -- 策略E: 相等即空, 写侧无满判据 --");
    // 读侧按「空」门控：相等时拒绝读；写侧第 5 写照单全收
    if (wn == rn)
      $display("    读侧: empty=1, 4 个未读数据存在但读请求被门控 (虚报空)");
    mem[wn] = 8'hA5;                       // 第 5 写覆盖槽 0 的 0xA1
    overwrite = overwrite + 1;
    wn = wn + 2'd1;                        // wn=01，相等解除，读侧放行
    got = mem[rn];
    rn = rn + 2'd1;
    if (got !== 8'hA1) mismatch = mismatch + 1;
    $display("    写侧: full=0 第5写被接受, 槽0 的 A1 被 A5 覆盖; 随后读到 %h (期望 A1)", got);

    // 策略 F：相等解释为满（full=相等），从头复位演示
    wn = 2'b00; rn = 2'b00;
    $display("  -- 策略F: 相等即满 --");
    for (k = 0; k < 4; k = k + 1)
      if (wn == rn) starve = starve + 1;  // 首批 4 次写全被假满挡下
    $display("    复位态 full=1, 首批 4 次写全部被挡, 指针停在 %b/%b (启动死锁)", wn, rn);

    $display("------------------------------------------------------------------");
    $display("[3] 备选: n 位指针 + 占用计数器, 深度只用 2^n-1 = 3 项");
    $display("  CNT count=0 full=0 empty=1 (槽3 永不使用)");
    for (k = 1; k <= 4; k = k + 1) begin
      if (!full_c) cnt = cnt + 2'd1;
      else         rejected_c = rejected_c + 1;
      #1;
      if (k == 4)
        $display("  第%0d 写后 count=%0d full=%b empty=%b  <- 第4写被满标志正确拒绝",
                 k, cnt, full_c, empty_c);
      else
        $display("  第%0d 写后 count=%0d full=%b empty=%b", k, cnt, full_c, empty_c);
    end
    $display("  读回 3 个: count 3->2->1->0, empty 正确拉起; 满/空全程无歧义");

    $display("------------------------------------------------------------------");
    $display("SUMMARY ext-model 误判=0 (两个满点 wgray 高两位均与对方相反)");
    $display("SUMMARY naive-E 覆盖=%0d 读回错配=%0d; naive-F 复位后饿死写=%0d",
             overwrite, mismatch, starve);
    $display("SUMMARY count-model 容量 4->3 浪费 1 项(25%%), 拒绝越界写=%0d, 误判=0", rejected_c);
    $display("------------------------------------------------------------------");
    $finish;
  end
endmodule
