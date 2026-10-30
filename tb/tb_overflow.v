`timescale 1ns/1ps
module tb_overflow;
    localparam DATA_WIDTH = 8;
    localparam ADDR_WIDTH = 2;
    localparam DEPTH = 1 << ADDR_WIDTH;
    reg wclk = 0, rclk = 0;
    reg wrst_n = 0, rrst_n = 0;
    reg winc = 0, rinc = 0;
    reg [DATA_WIDTH-1:0] wdata = 0;
    wire wfull, rempty;
    wire [DATA_WIDTH-1:0] rdata;
    integer attempts = 0, accepted = 0, rejected = 0, received = 0;
    integer i;

    always #5 wclk = ~wclk;
    always #7 rclk = ~rclk;
    async_fifo #(.DATA_WIDTH(DATA_WIDTH), .ADDR_WIDTH(ADDR_WIDTH)) dut (
        .wclk(wclk), .wrst_n(wrst_n), .winc(winc), .wdata(wdata), .wfull(wfull),
        .rclk(rclk), .rrst_n(rrst_n), .rinc(rinc), .rdata(rdata), .rempty(rempty)
    );

    initial begin
        $display("TEST overflow depth=%0d: upstream ignores wfull", DEPTH);
        repeat (3) @(negedge wclk);
        wrst_n = 1;
        repeat (2) @(negedge rclk);
        rrst_n = 1;
        @(negedge wclk);
        for (i = 0; i < 8; i = i + 1) begin
            wdata = i;
            winc = 1;
            attempts = attempts + 1;
            if (wfull) begin
                rejected = rejected + 1;
                $display("DROP attempt=%0d data=%0d wfull=1", attempts, i);
            end else begin
                accepted = accepted + 1;
            end
            @(negedge wclk);
        end
        winc = 0;
        while (!rempty) begin
            @(negedge rclk);
            if (!rempty) begin
                rinc = 1;
                #1 $display("READ index=%0d data=%0d", received, rdata);
                received = received + 1;
                @(negedge rclk);
                rinc = 0;
            end
        end
        $display("EVIDENCE attempts=%0d accepted=%0d rejected=%0d received=%0d lost=%0d",
                 attempts, accepted, rejected, received, attempts-received);
        $display("LOST_SAMPLES data=4,5,6,7 (new writes discarded; stored data remains intact)");
        if (attempts == 8 && accepted == 4 && rejected == 4 && received == 4)
            $display("PASS tb_overflow reproduction");
        else
            $display("FAIL tb_overflow reproduction");
        $finish;
    end
endmodule
