// tb_almost_threshold.v
// FIFO almost-full 阈值扫描实验（自包含行为模型，不依赖 rtl 目录）
// 模型：单时钟占用计数 FIFO；afull = (occ >= AFULL_THRESH)；
//       afull 经 N_SYNC=2 级同步延迟 + N_RESP 拍上游响应延迟后才真正停写；
//       写端始终背靠背有数据；读端周期性停顿制造反压。
// 扫描：同一激励跑多档阈值，统计 接受写入 / 写气泡 / 最大占用 / 溢出。
`timescale 1ns/1ps
module tb_almost_threshold;

  localparam integer DEPTH  = 16;
  localparam integer N_SYNC = 2;       // afull 跨域两级同步（写时钟域拍数）
  localparam integer CYCLES = 400;     // 每档仿真长度（25 个 16 拍周期）
  localparam integer EPOCH   = 16;     // 读端每周期：前 8 拍排空、后 8 拍完全停顿
  localparam integer RD_RUN  = 8;      // 排空阶段读端连续读
  localparam integer RD_STOP = 8;      // 停顿阶段读端完全不读（最坏情况反压窗口）

  integer cyc;
  integer occ, maxocc, nwrite, nread, nbubble, noverf;
  integer thresh, nresp, D;
  integer raw;                        // 组合 afull（当前占用比较）
  integer do_wr, do_rd;
  reg [7:0] pipe;                     // afull 延迟线（同步+响应）
  integer first_ovf_cyc, first_ovf_occ;
  integer total_ovf;

  initial begin
    total_ovf = 0;
    $display("==================================================================");
    $display(" FIFO almost-full 阈值扫描 (DEPTH=%0d, 写端背靠背, 读端 %0d拍排空/%0d拍完全停顿)",
             DEPTH, RD_RUN, RD_STOP);
    $display(" afull = (occ >= thresh); 提前量 lookahead = DEPTH - thresh");
    $display(" 反压环路延迟 D = N_SYNC(%0d) + N_RESP; 安全预算 thresh <= DEPTH - D",
             N_SYNC);

    // ---- 组 A：上游组合 ready，收到同步后 afull 当拍即可停写（N_RESP=0）----
    $display("------------------------------------------------------------------");
    $display(" [组A] N_RESP=0 (上游无 skid, 反压当拍生效) 预算 thresh <= %0d",
             DEPTH - N_SYNC);
    $display("  thresh lookahead | 接受写入  写气泡  最大占用  溢出");
    run_case(0, 4);
    run_case(0, 8);
    run_case(0, 12);
    run_case(0, 14);
    run_case(0, 15);

    // ---- 组 B：上游带一级 skid，收到反压后还会再发 1 拍（N_RESP=1）----
    $display("------------------------------------------------------------------");
    $display(" [组B] N_RESP=1 (上游一级 skid, 反压后仍发 1 拍) 预算 thresh <= %0d",
             DEPTH - N_SYNC - 1);
    $display("  thresh lookahead | 接受写入  写气泡  最大占用  溢出");
    run_case(1, 8);
    run_case(1, 12);
    run_case(1, 13);
    run_case(1, 14);

    $display("------------------------------------------------------------------");
    $display("SUMMARY: 扫描 9 档, 溢出事件合计 %0d (仅应出现在超过预算的档位)",
             total_ovf);
    $display("         组A 安全档位(4/8/12/14)溢出必须为 0; 15 超出预算必须复现溢出");
    $display("         组B 13 为临界(占用顶到 %0d), 14 超出预算必须溢出", DEPTH);
    $finish;
  end

  task run_case(input integer resp, input integer thr);
    begin
      nresp   = resp;
      thresh  = thr;
      D       = N_SYNC + nresp;
      occ     = 0;
      maxocc  = 0;
      nwrite  = 0;
      nread   = 0;
      nbubble = 0;
      noverf  = 0;
      first_ovf_cyc = -1;
      first_ovf_occ = -1;
      pipe    = 8'b0;

      for (cyc = 1; cyc <= CYCLES; cyc = cyc + 1) begin
        // 组合比较：当前占用达到阈值即拉起 afull
        raw = (occ >= thresh) ? 1 : 0;
        // 上游实际看到的停写令：afull 延迟 D 拍
        do_wr = (pipe[D-1] == 1'b1) ? 0 : 1;
        // 读端周期：每 EPOCH 拍前 RD_RUN 拍连续读，其后完全停顿；空 FIFO 不读
        do_rd = (((cyc - 1) % EPOCH) < RD_RUN && occ > 0) ? 1 : 0;
        // 同拍读写：满 FIFO 当拍有读出时允许写入
        if (do_wr && occ == DEPTH && !do_rd) begin
          noverf = noverf + 1;                    // 写满且无同拍读：溢出
          if (first_ovf_cyc < 0) begin
            first_ovf_cyc = cyc;
            first_ovf_occ = occ;
          end
        end
        // 写气泡：想写但被反压挡住，且 FIFO 其实还有空位
        if (!do_wr && occ < DEPTH) nbubble = nbubble + 1;
        // 沿更新
        if (do_rd) nread = nread + 1;
        if (do_wr && !(occ == DEPTH && !do_rd)) nwrite = nwrite + 1;
        occ = occ + ((do_wr && !(occ == DEPTH && !do_rd)) ? 1 : 0)
                   - (do_rd ? 1 : 0);
        if (occ > maxocc) maxocc = occ;
        pipe = {pipe[6:0], raw[0]};
      end

      total_ovf = total_ovf + noverf;
      $display("  %6d %9d | %8d %7d %9d %5d",
               thresh, DEPTH - thresh, nwrite, nbubble, maxocc, noverf);
      if (first_ovf_cyc >= 0)
        $display("           -> 首次溢出: cyc=%0d, 停写令到达时 occ=%0d (thresh=%0d, D=%0d)",
                 first_ovf_cyc, first_ovf_occ, thresh, D);
    end
  endtask

endmodule
