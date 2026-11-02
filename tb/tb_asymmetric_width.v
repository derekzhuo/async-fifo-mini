// tb_asymmetric_width.v
// 非对称位宽 FIFO（asymmetric-width FIFO）拼拆逻辑与满空换算实验
// 自包含行为模型，不依赖 rtl 目录：存储体统一按窄侧 entry unit（1 字节）组织，
// 读写指针全部以 entry unit 为单位；宽侧一拍推进 RATIO，窄侧一拍推进 1。
//   实验1 写32读8 (WIDE_WRITE=1)：连写 4 个 32 位字 = 16 字节，逐字节读出并
//         CHECK 字节序（低字节占低地址，小端排布）；含同拍先读后写的满判定。
//   实验2 写8读32 (WIDE_WRITE=0)：只写 2 字节时宽读不得出数；凑齐 4 字节汇聚
//         成一拍宽字读出；填满 16 字节观察 full。
`timescale 1ns/1ps
module tb_asymmetric_width;

  localparam integer DEPTH = 16;   // 存储深度，按窄侧 entry unit（字节）计
  localparam integer RATIO = 4;    // 32/8 = 4，仅支持 2 的幂比率

  reg [7:0] mem [0:DEPTH-1];
  integer wp, rp;                  // 写/读指针，单位均为 entry unit
  integer occ;                     // 窄侧占用计数 = wp - rp
  integer cyc, i, b, err, tick;
  reg [31:0] wword, rword;
  reg [7:0]  rbyte;
  integer wide_ok;

  // 同拍模型：先执行读后执行写，full 判定计入当拍腾出的槽
  task automatic do_cycle;
    input integer do_wr;           // 本拍是否写
    input integer do_rd;           // 本拍是否读
    input integer wide_wr;         // 1=写侧是32位宽口, 0=写侧是8位窄口
    input [31:0] wdata;            // 写数据（窄口只用低 8 位）
    integer need, freed, j;
    begin
      tick = tick + 1;
      freed = 0;
      // ---- 先读：宽读一次取 RATIO 个槽，窄读取 1 个 ----
      if (do_rd) begin
        if (wide_wr) begin
          // 写32读8：读 1 字节
          if (occ < 1) $display("  [cyc=%0d] ERROR: 窄读时 FIFO 已空", $time);
          else begin rbyte = mem[rp % DEPTH]; rp = rp + 1; freed = 1; end
        end else begin
          // 写8读32：必须攒够 RATIO 字节才允许宽读
          if (occ < RATIO)
            $display("  [cyc=%0d] 宽读未执行：窄侧占用 %0d < %0d，禁止提前拼字",
                     tick, occ, RATIO);
          else begin
            rword = 32'h0;
            for (j = 0; j < RATIO; j = j + 1)
              rword[j*8 +: 8] = mem[(rp + j) % DEPTH];
            rp = rp + RATIO; freed = RATIO;
            $display("  [cyc=%0d] 宽读出数 0x%08h（由 %0d 个窄侧槽汇聚）",
                     tick, rword, RATIO);
          end
        end
      end
      // ---- 后写：宽写需要 RATIO 个空槽，窄写需要 1 个；计入当拍腾出的槽 ----
      if (do_wr) begin
        need = wide_wr ? RATIO : 1;
        if (DEPTH - (occ - freed) < need)
          $display("  [cyc=%0d] 写被拒：空槽 %0d（含当拍腾出 %0d）< 本次需要 %0d",
                   tick, DEPTH - (occ - freed), freed, need);
        else begin
          if (wide_wr) begin
            for (j = 0; j < RATIO; j = j + 1)
              mem[(wp + j) % DEPTH] = wdata[j*8 +: 8]; // 低字节占低地址
            wp = wp + RATIO;
          end else begin
            mem[wp % DEPTH] = wdata[7:0];
            wp = wp + 1;
          end
        end
      end
      occ = wp - rp;
    end
  endtask

  function integer is_full;
    input integer wide_wr;
    integer need;
    begin
      need = wide_wr ? RATIO : 1;   // 满判定按「下一拍写需要几个槽」
      is_full = (DEPTH - occ) < need;
    end
  endfunction

  initial begin
    err = 0; cyc = 0; tick = 0; wp = 0; rp = 0; occ = 0;
    $display("==================================================================");
    $display(" 非对称位宽 FIFO 实验：存储统一按窄侧 entry unit 组织 (DEPTH=%0d 字节, 比率 %0d:1)",
             DEPTH, RATIO);
    $display(" 指针单位：写32读8 时写指针每拍 +%0d、读指针 +1；写8读32 反之", RATIO);

    // ================= 实验1：写 32 读 8 =================
    $display("------------------------------------------------------------------");
    $display(" [实验1] 写32位/读8位：连写 4 个宽字，逐字节读回并 CHECK 字节序");
    // 4 个宽字，每字节取值互不相同，任何错位/颠倒都会被 CHECK 抓住
    do_cycle(1,0,1,32'h7A7B7C7D);  #10;
    $display("  写 W0=0x7A7B7C7D 后 occ=%0d (full=%0d empty=%0d)",
             occ, is_full(1), occ==0);
    do_cycle(1,0,1,32'h6A6B6C6D);  #10;
    $display("  写 W1=0x6A6B6C6D 后 occ=%0d (full=%0d)", occ, is_full(1));
    do_cycle(1,0,1,32'h5A5B5C5D);  #10;
    $display("  写 W2=0x5A5B5C5D 后 occ=%0d (full=%0d)", occ, is_full(1));
    do_cycle(1,0,1,32'h4A4B4C4D);  #10;
    $display("  写 W3=0x4A4B4C4D 后 occ=%0d (full=%0d empty=%0d)",
             occ, is_full(1), occ==0);

    // 逐字节读回全部 16 字节并 CHECK（低字节占低地址：7D 7C 7B 7A ...）
    $display("  -- 逐字节读回（存储低地址 -> 高地址），16 项字节序 CHECK --");
    begin : CHECK1
      integer expv;   // 期望值：Wn 四字节低->高为 (7D-16n),(7C-16n),(7B-16n),(7A-16n)
      for (b = 0; b < 16; b = b + 1) begin
        expv = 8'h7D - (b/4)*16 - (b%4);
        do_cycle(0,1,1,0); #10;
        $display("  CHECK byte[%0d] = 0x%02h (expect 0x%02h) %s",
                 b, rbyte, expv[7:0], (rbyte===expv[7:0]) ? "OK":"FAIL");
        if (rbyte !== expv[7:0]) err = err + 1;
      end
    end
    $display("  字节序结论：宽字 0x7A7B7C7D 拆成 7D 7C 7B 7A（低字节占低地址，小端排布）");
    $display("  读空 W0..W3 后 occ=%0d (empty=%0d)", occ, occ==0);

    // 同拍先读后写：重新填满 4 个宽字，occ=16 时演示满判定计入当拍腾出槽
    $display("  -- 同拍场景：occ=16 时只腾出 1 槽宽写被拒；凑够 4 槽的当拍宽写成功 --");
    do_cycle(1,0,1,32'h7A7B7C7D); #10; do_cycle(1,0,1,32'h6A6B6C6D); #10;
    do_cycle(1,0,1,32'h5A5B5C5D); #10; do_cycle(1,0,1,32'h4A4B4C4D); #10;
    $display("  重新写满 4 宽字后 occ=%0d (full=%0d)", occ, is_full(1));
    do_cycle(1,1,1,32'h3A3B3C3D);  #10; // 只腾出 1，仍应拒绝
    $display("  读写同拍只腾出 1 槽：occ=%0d, 宽写被拒（需要 4 槽）", occ);
    do_cycle(0,1,1,0); #10; do_cycle(0,1,1,0); #10; do_cycle(0,1,1,0); #10;
    $display("  再窄读 3 次后 occ=%0d（累计腾出 4 槽中的前 3 槽）", occ);
    do_cycle(1,1,1,32'h3A3B3C3D);  #10;
    $display("  第 4 次窄读与宽写同拍后 occ=%0d（当拍先腾出第 4 槽，W4 写入成功）", occ);

    // ================= 实验2：写 8 读 32 =================
    $display("------------------------------------------------------------------");
    $display(" [实验2] 写8位/读32位：汇聚未满 4 字节时宽读禁止出数");
    wp = 0; rp = 0; occ = 0; tick = 0;
    do_cycle(1,0,0,32'h00000011); #10;
    do_cycle(1,0,0,32'h00000022); #10;
    $display("  写入 2 字节 11 22 后 occ=%0d", occ);
    do_cycle(0,1,0,0); #10;   // 宽读尝试：应被拒绝
    $display("  此时宽读出数无效，occ 仍为 %0d（半拍宽字不得提前输出）", occ);
    do_cycle(1,0,0,32'h00000033); #10;
    do_cycle(1,0,0,32'h00000044); #10;
    $display("  再写 33 44，occ=%0d，凑齐 4 字节", occ);
    do_cycle(0,1,0,0); #10;   // 宽读出数 0x44332211
    $display("  CHECK 汇聚宽字 = 0x%08h (expect 0x44332211) %s, 读后 occ=%0d",
             rword, (rword===32'h44332211)?"OK":"FAIL", occ);
    if (rword !== 32'h44332211) err = err + 1;

    // 填满观察窄侧 full：连续写 16 字节
    for (i = 0; i < 16; i = i + 1) do_cycle(1,0,0,32'h80+i);
    #10;
    $display("  连续写 16 字节后 occ=%0d (full=%0d)：窄侧 1 拍 1 槽，满在 occ=%0d",
             occ, is_full(0), DEPTH);
    do_cycle(1,0,0,32'hFF); #10;  // 第 17 字节应被拒
    $display("  第 17 字节写入后 occ 仍=%0d（被 full 拒绝，无覆盖）", occ);

    $display("------------------------------------------------------------------");
    if (err == 0)
      $display("RESULT: PASS — 32->8 字节序 16 项 CHECK 全 OK，8->32 汇聚 CHECK OK，半字边界与满判定正确");
    else
      $display("RESULT: FAIL — %0d 项 CHECK 未通过", err);
    $display("==================================================================");
    $finish;
  end
endmodule
