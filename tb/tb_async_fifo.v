`timescale 1ns/1ps
module tb_async_fifo;
    localparam DATA_WIDTH = 8;
    localparam ADDR_WIDTH = 4;
    localparam DEPTH = 1 << ADDR_WIDTH;

    reg wclk = 0, rclk = 0;
    reg wrst_n = 0, rrst_n = 0;
    reg winc = 0, rinc = 0;
    reg [DATA_WIDTH-1:0] wdata = 0;
    wire wfull, rempty;
    wire [DATA_WIDTH-1:0] rdata;
    reg [DATA_WIDTH-1:0] expected [0:8191];
    integer writes = 0, reads = 0, errors = 0;
    integer i, wi, ri;
    reg [DATA_WIDTH-1:0] value;

    always #5 wclk = ~wclk;
    always #7 rclk = ~rclk;

    async_fifo #(.DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(ADDR_WIDTH)) dut (
        .wclk(wclk), .wrst_n(wrst_n), .winc(winc), .wdata(wdata), .wfull(wfull),
        .rclk(rclk), .rrst_n(rrst_n), .rinc(rinc), .rdata(rdata), .rempty(rempty)
    );

    task push(input [DATA_WIDTH-1:0] data);
        begin
            @(negedge wclk);
            while (wfull) @(negedge wclk);
            wdata = data;
            winc = 1;
            @(negedge wclk);
            winc = 0;
            expected[writes] = data;
            writes = writes + 1;
        end
    endtask

    task pop;
        begin
            @(negedge rclk);
            while (rempty) @(negedge rclk);
            rinc = 1;
            #1 value = rdata;
            if (value !== expected[reads]) begin
                $display("ERROR read=%0d expected=%0d actual=%0d", reads, expected[reads], value);
                errors = errors + 1;
            end
            @(negedge rclk);
            rinc = 0;
            reads = reads + 1;
        end
    endtask

    initial begin
        $display("TEST async_fifo depth=%0d width=%0d", DEPTH, DATA_WIDTH);
        repeat (3) @(negedge wclk);
        wrst_n = 1;
        repeat (2) @(negedge rclk);
        rrst_n = 1;

        $display("PHASE fill-to-full");
        for (i = 0; i < DEPTH; i = i + 1) push(i);
        repeat (2) @(negedge wclk);
        if (!wfull) begin
            $display("ERROR full flag not asserted at capacity");
            errors = errors + 1;
        end
        $display("PHASE drain-to-empty");
        for (i = 0; i < DEPTH; i = i + 1) pop;
        repeat (3) @(negedge rclk);
        if (!rempty) begin
            $display("ERROR empty flag not asserted after drain");
            errors = errors + 1;
        end

        $display("PHASE wraparound sequential traffic");
        for (i = 0; i < 4*DEPTH; i = i + 1) begin
            push(8'h40 + i);
            pop;
        end
        while (reads < writes) pop;

        writes = 0;
        reads = 0;
        $display("PHASE concurrent random traffic");
        fork
            for (wi = 0; wi < 250; wi = wi + 1) push($random);
            for (ri = 0; ri < 250; ri = ri + 1) pop;
        join
        repeat (4) @(negedge rclk);
        $display("STATS writes=%0d reads=%0d errors=%0d", writes, reads, errors);
        if (errors == 0 && writes == 250 && reads == 250)
            $display("PASS tb_async_fifo");
        else
            $display("FAIL tb_async_fifo");
        $finish;
    end
endmodule
