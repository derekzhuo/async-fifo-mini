`timescale 1ns/1ps
// tb_full_empty_semantics.v
// 目的：实证异步 FIFO 满/空标志的两条语义：
//   1) 两拍跨域同步让标志相对「真实占用」滞后，且误差永远偏保守
//      （虚报满 = 写侧被挡住产生气泡；虚报空 = 读侧被挡住产生气泡）；
//   2) 保守方向保证数据完整性：整个实验 overflow / underflow / 数据错配恒为 0。
// 配置：深度 16，wclk=10ns(100MHz)，rclk=17ns(~59MHz)，异步无整数倍关系。
module tb_full_empty_semantics;
    localparam DATA_WIDTH = 8;
    localparam ADDR_WIDTH = 4;
    localparam DEPTH = 1 << ADDR_WIDTH;

    reg wclk = 0, rclk = 0;
    reg wrst_n = 0, rrst_n = 0;
    reg winc = 0, rinc = 0;
    reg [DATA_WIDTH-1:0] wdata = 0;
    wire wfull, rempty;
    wire [DATA_WIDTH-1:0] rdata;

    always #5  wclk = ~wclk;
    always #8.5 rclk = ~rclk;

    async_fifo #(.DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(ADDR_WIDTH)) dut (
        .wclk(wclk), .wrst_n(wrst_n), .winc(winc), .wdata(wdata), .wfull(wfull),
        .rclk(rclk), .rrst_n(rrst_n), .rinc(rinc), .rdata(rdata), .rempty(rempty)
    );

    // ---- 真值模型：写侧/读侧各自记录本侧被接受的操作数 ----
    integer nw = 0, nr = 0;          // 已接受写/读个数
    integer wcy = 0, rcy = 0;        // 时钟沿序号
    integer w_req = 0, r_req = 0;    // 请求周期数
    integer w_bub_real = 0;          // 真满时被挡（合理反压）
    integer w_bub_cons = 0;          // 虚报满：实际有空位却被挡（写气泡）
    integer r_bub_real = 0;          // 真空时被挡
    integer r_bub_cons = 0;          // 虚报空：实际有数据却被挡（读气泡）
    integer err_overflow = 0, err_underflow = 0, err_data = 0;

    // 软件参考队列，用于逐拍核对 rdata
    reg [DATA_WIDTH-1:0] qmem [0:255];
    integer qh = 0, qt = 0;

    integer phase = 0;
    integer trial;
    integer wcy_lastread;           // 最近一次读被接受时的 wclk 沿号
    integer rcy_lastwrite;          // 最近一次写被接受时的 rclk 沿号
    integer flg_lag [0:7];          // 每次「读1个→full 撤销」的 wclk 滞后拍数
    integer emp_lag [0:7];          // 每次「写1个→empty 撤销」的 rclk 滞后拍数
    reg was_full = 0, was_empty = 1;

    function integer occ;
        begin occ = nw - nr; end
    endfunction

    // ---- 写侧驱动与统计 ----
    always @(posedge wclk) begin
        wcy = wcy + 1;
        if (wrst_n === 1'b1) begin
            if (winc) w_req = w_req + 1;
            if (winc && !wfull) begin
                // 本沿被接受（用沿前标志判定，与 RTL 内部同一口径）
                if (nw - nr == DEPTH) err_overflow = err_overflow + 1;
                qmem[qt[7:0]] = wdata; qt = qt + 1;
                nw = nw + 1;
                if (phase == 4) rcy_lastwrite = rcy;
            end else if (winc && wfull) begin
                if (nw - nr == DEPTH) w_bub_real = w_bub_real + 1;
                else                   w_bub_cons = w_bub_cons + 1;
            end
        end
    end

    // ---- 读侧驱动与统计 ----
    always @(posedge rclk) begin
        rcy = rcy + 1;
        if (rrst_n === 1'b1) begin
            if (rinc) r_req = r_req + 1;
            if (rinc && !rempty) begin
                if (nw - nr == 0) err_underflow = err_underflow + 1;
                if (rdata !== qmem[qh[7:0]]) begin
                    err_data = err_data + 1;
                    $display("[%0t] DATA MISMATCH exp=%0h got=%0h", $time,
                             qmem[qh[7:0]], rdata);
                end
                qh = qh + 1;
                nr = nr + 1;
                wcy_lastread = wcy;
            end else if (rinc && rempty) begin
                if (nw - nr == 0) r_bub_real = r_bub_real + 1;
                else               r_bub_cons = r_bub_cons + 1;
            end
        end
    end

    // ---- full 撤销滞后记录（1→0 沿）----
    always @(posedge wclk) #1 begin
        if (phase == 2 && was_full && !wfull)
            flg_lag[trial] = wcy - wcy_lastread;
        was_full = wfull;
    end

    // ---- empty 撤销滞后记录（1→0 沿）----
    always @(posedge rclk) #1 begin
        if (phase == 4 && was_empty && !rempty)
            emp_lag[trial] = rcy - rcy_lastwrite;
        was_empty = rempty;
    end

    // ---- 复位 ----
    initial begin
        #42  wrst_n = 1;
        #19  rrst_n = 1;   // #61，刻意错开放置
    end

    // ---- 写侧场景编排 ----
    initial begin
        @(posedge wrst_n);
        repeat (3) @(posedge wclk);
        // 阶段 1：连续写 16 个填满，再请求 2 次第 17 个（必须被挡）
        phase = 1;
        for (trial = 0; trial < DEPTH; trial = trial + 1) begin
            @(posedge wclk);
            winc <= 1; wdata <= 8'hA0 + trial[7:0];
            @(posedge wclk);
            winc <= 0;
        end
        @(posedge wclk); #1;
        $display("[%0t] PHASE1 fill done: occ=%0d wfull=%b (TRUE_FULL vs flag 同沿可见)",
                 $time, nw - nr, wfull);
        @(posedge wclk); winc <= 1; wdata <= 8'hFF;
        @(posedge wclk); #1;
        $display("[%0t] PHASE1 17th request : occ=%0d wfull=%b (越界写被门控)",
                 $time, nw - nr, wfull);
        @(posedge wclk); winc <= 0;

        // 阶段 2：写请求常高；读侧每次读 1 个，统计 full 撤销滞后与写气泡
        wait (phase == 2);
        @(posedge wclk); winc <= 1;
        wait (phase == 3);
        @(posedge wclk); winc <= 0;

        // 阶段 3：写侧空闲，等读侧抽空
        wait (phase == 4);
        // 阶段 4：读请求常高，写侧每次只写 1 个，统计 empty 撤销滞后与读气泡
        for (trial = 0; trial < 8; trial = trial + 1) begin
            wait (nw - nr == 0);
            @(posedge wclk);
            winc <= 1; wdata <= 8'h50 + trial[7:0];
            @(posedge wclk); winc <= 0;
            wait (nw - nr == 0);  // 该数据被读走即进入下一 trial
        end
        wait (phase == 5);
    end

    // ---- 读侧场景编排 ----
    integer i;
    initial begin
        @(posedge rrst_n);
        repeat (3) @(posedge rclk);
        wait (phase == 1); wait (nw - nr == DEPTH);
        @(posedge rclk);

        // 阶段 2：8 次「读 1 个 → 等写侧补回 → 再读」
        phase = 2;
        for (trial = 0; trial < 8; trial = trial + 1) begin
            wait (nw - nr == DEPTH);
            @(posedge rclk); rinc <= 1;
            @(posedge rclk); #1 rinc <= 0;
            $display("[%0t] PHASE2 trial%0d: read 1, occ=%0d, wfull still=%b (虚报满窗口开始)",
                     $time, trial + 1, nw - nr, wfull);
            wait (nw - nr == DEPTH);  // 写侧补满后再开始下一次
        end
        phase = 3;

        // 阶段 3：连续读抽空 FIFO，再多请求 2 拍（必须被挡）
        rinc <= 1;
        wait (nw - nr == 0);
        @(posedge rclk); #1;
        $display("[%0t] PHASE3 drain done: occ=%0d rempty=%b (真空)", $time, nw - nr, rempty);
        @(posedge rclk);
        $display("[%0t] PHASE3 extra read : occ=%0d rempty=%b (越界读被门控)",
                 $time, nw - nr, rempty);
        @(posedge rclk); rinc <= 0;

        // 阶段 4：读请求常高，等写侧逐个投喂
        phase = 4;
        @(posedge rclk); rinc <= 1;
        wait (phase == 5);
        @(posedge rclk); rinc <= 0;
    end

    // ---- 收尾汇总 ----
    initial begin
        wait (phase == 4);
        // 等 8 轮 empty 实验全部完成
        wait (nw == DEPTH + 8 + 8);   // 16 首填 + 阶段2补8 + 阶段4写8
        #100 phase = 5;
        #50;
        $display("---------------------------------------------------------------");
        $display("CONFIG depth=%0d wclk=10ns rclk=17ns (异步, 无整数倍关系)", DEPTH);
        for (i = 0; i < 8; i = i + 1)
            $display("FULL   trial%0d: read 后 wfull 撤销滞后 = %0d 个 wclk 周期", i + 1, flg_lag[i]);
        for (i = 0; i < 8; i = i + 1)
            $display("EMPTY  trial%0d: write 后 rempty 撤销滞后 = %0d 个 rclk 周期", i + 1, emp_lag[i]);
        $display("BUBBLE write-side: 虚报满气泡=%0d 拍 (真满反压=%0d 拍, 合理)",
                 w_bub_cons, w_bub_real);
        $display("BUBBLE read-side : 虚报空气泡=%0d 拍 (真空等待=%0d 拍, 合理)",
                 r_bub_cons, r_bub_real);
        $display("SAFETY overflow=%0d underflow=%0d data-mismatch=%0d",
                 err_overflow, err_underflow, err_data);
        $display("THROUGHPUT 8 次「读1写1」往返中, 写侧因保守满标志净损失 %0d 个写周期",
                 w_bub_cons);
        $display("---------------------------------------------------------------");
        $finish;
    end
endmodule
