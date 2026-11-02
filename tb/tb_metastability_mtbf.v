// tb_metastability_mtbf.v
// 亚稳态数字注错模型：单级 / 两级 / 三级同步器对照实验
//
// 真实硅片上，跨域 D 输入若在目的沿的建立时间窗内翻转，第一级触发器
// 输出会悬在中间电平，再以工艺分辨时间常数 tau 指数衰减到 0 或 1。
// 行为级仿真器没有模拟分辨率，无法再现中间电平，这里用 4 态逻辑的 X
// 作为「亚稳态」的数字注错：
//   - 翻转刻意安排在目的沿前 0.5ns（落在 2ns 建立窗内）-> 第一级采到 X；
//   - X 占据若干个目的周期后在周期中途（下降沿）分辨为确定值，
//     分辨耗时 resol 按试次给定（10 次中 9 次 1 拍、1 次 2 拍，
//     代表「大多数在一个周期内收敛、偶尔需要更久」的条件分布）；
//   - 单级路径：X 当拍即扇出给组合逻辑（FIFO 满空比较器），
//     且下游两个触发器在 X 未收敛时独立判决，可能一个判 0 一个判 1；
//   - 两级路径：第二级在 X 收敛后的沿采样；只有 resol=2 的试次采到 1 拍 X；
//   - 三级路径：第三级再获得一整个周期，全部试次干净。
//
// 注意：本实验只演示结构性质（X 在哪一级被拦住、输出非旧即新），
// 不产生 MTBF 数字；失效率量级由器件参数代入 MTBF 公式计算，见配套文档。
`timescale 100ps/100ps
module tb_metastability_mtbf;

  // 目的时钟 10ns（100MHz）
  reg clk = 1'b0;
  always #50 clk = ~clk;

  reg d = 1'b0;           // 跨域输入（格雷码指针的某一个 bit）
  reg s1, s2, s3;        // 三级采样链
  reg c_a, c_b;          // 单级路径的两个下游判决触发器（模拟扇出分叉）

  // 单级路径：s1 直接进组合逻辑（等价于满空比较式里的指针比较）
  wire fan_and = s1 & 1'b1;
  wire fan_or  = s1 | 1'b0;

  integer trial;
  integer resol;                  // 本次注错分辨耗时（目的周期数）
  integer direct_x = 0;          // X 当拍扇出到组合逻辑的次数
  integer diverge   = 0;          // 下游两个判决器分裂的次数
  integer s2_x      = 0;          // 第二级采到 X 的周期数
  integer s3_x      = 0;          // 第三级采到 X 的周期数
  integer illegal_s2 = 0;         // 观察点第二级出现非 0/1 的次数
  integer illegal_s3 = 0;
  reg e0_fan;                     // E0 当拍组合扇出端的采样值

  // 时间轴（单位 0.1ns）：E0 违例沿；+50 下降沿；+100 E1；
  // +150 下降沿；+200 E2；+250 下降沿；+300 E3。
  task run_trial(input integer r, input integer vf, input integer split);
    integer e0;
    begin
      @(posedge clk); #45;             // 距下一个上升沿 0.5ns
      d = ~d;                           // 跨域 bit 在建立窗内翻转
      #5;                               // -> E0：违例沿
      e0 = $time;
      s1 = 1'bx;                        // 第一级注错：采到亚稳态
      #1;                               // E0 当拍：X 已在组合扇出端
      e0_fan = fan_or;
      if (fan_and === 1'bx || fan_or === 1'bx) direct_x = direct_x + 1;

      #49;                              // -> E0 后下降沿
      if (r == 1) s1 = vf;             // 1 拍分辨：周期中途收敛

      #50;                              // -> E1
      if (r == 1) begin
        s2   = vf;                      // 第二级沿采样时电平已稳定
        c_a  = vf; c_b = vf;
      end else begin
        s2   = 1'bx;                    // 第一级仍悬摆 -> 第二级也进亚稳态
        s2_x = s2_x + 1;
        // 单级路径：两个下游触发器在同一沿独立判决
        c_a = split ? 1'b0 : vf;
        c_b = split ? 1'b1 : vf;
        if (c_a !== c_b) diverge = diverge + 1;
      end

      #50;                              // -> 第二周期下降沿
      if (r == 2) begin
        s1 = vf;                        // 第一级终于收敛
        s2 = vf;                        // 第二级也在自身一周期内分辨完毕
      end

      #50;                              // -> E2：第三级沿采样
      s3 = s2;
      if (s2 === 1'bx) s3_x = s3_x + 1;
      #1;
      $display("TRIAL %0d t=%0t resol=%0d | E0扇出=%b 下游判决A/B=%b%b | 收敛后 s2=%b s3=%b",
               trial, e0, r, e0_fan, c_a, c_b, s2, s3);
      if (s2 !== 1'b0 && s2 !== 1'b1) illegal_s2 = illegal_s2 + 1;
      if (s3 !== 1'b0 && s3 !== 1'b1) illegal_s3 = illegal_s3 + 1;

      #49;                              // -> 下降沿，恢复稳态
      s1 = d; s2 = d; s3 = d; c_a = d; c_b = d;
      @(posedge clk);                   // E3 对齐后进入下一试次
    end
  endtask

  integer vfin;
  initial begin
    $display("---------------------------------------------------------------");
    $display("CONFIG f_dst=100MHz(T=10ns) 建立窗违例偏移=0.5ns 注错试次=10");
    $display("MODEL X=亚稳态数字注错; resol=第一级分辨耗时(周期), 9 次=1, 1 次=2");
    $display("---------------------------------------------------------------");
    s1 = 1'b0; s2 = 1'b0; s3 = 1'b0; c_a = 1'b0; c_b = 1'b0;
    @(posedge clk);

    for (trial = 1; trial <= 10; trial = trial + 1) begin
      resol = (trial == 7) ? 2 : 1;
      vfin  = trial % 2;               // 终值交替，等价旧值/新值交替
      run_trial(resol, vfin, (trial == 7) ? 1 : 0);
    end

    $display("---------------------------------------------------------------");
    $display("SUMMARY direct-X-propagate=%0d/10 (单级: X 当拍进组合逻辑)", direct_x);
    $display("SUMMARY downstream-diverge=%0d/10 (单级: 两个下游判决器分裂)", diverge);
    $display("SUMMARY stage2-X-cycles=%0d (两级: 仅 resol=2 试次采到 1 拍 X)", s2_x);
    $display("SUMMARY stage3-X-cycles=%0d (三级: 0)", s3_x);
    $display("SUMMARY E2观察点非0/1: stage2=%0d stage3=%0d", illegal_s2, illegal_s3);

    // ---- 格雷码单 bit 演示：单位翻转不豁免亚稳态 ----
    // 格雷指针 G(1)=0010 -> G(2)=0011，仅 bit0 翻转；翻转落在建立窗内。
    begin: gray_demo
      reg [3:0] gp;
      reg gb_s1, gb_s2;
      gp = 4'b0010; gb_s1 = 1'b0; gb_s2 = 1'b0;
      @(posedge clk); #45;
      gp = 4'b0011;                    // 只有 bit0 变
      #5;                              // E0
      gb_s1 = 1'bx;                    // 翻转的那一根线照样进亚稳态
      #50;                             // 下降沿：一个周期内收敛
      gb_s1 = gp[0];
      #50;                             // E1：第二级沿采样
      gb_s2 = gb_s1;
      $display("GRAY  G1=0010->G2=0011 单 bit 翻转: 第一级仍采到 X, 两级后 s2=%b (非旧即新)", gb_s2);
      $display("GRAY  结论: 格雷码只消除多位非法组合, 单 bit 的亚稳态必须靠打拍收敛");
    end

    $display("---------------------------------------------------------------");
    $finish;
  end
endmodule
