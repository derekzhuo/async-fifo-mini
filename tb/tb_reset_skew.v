`timescale 1ns/1ps
module tb_reset_skew;
    reg wclk = 0, rclk = 0;
    reg wrst_n = 0, rrst_n = 0;
    reg winc = 0, rinc = 0;
    reg [7:0] wdata = 0;
    wire wfull, rempty;
    wire [7:0] rdata;
    integer stale_cycles = 0;
    integer errors = 0;

    always #5 wclk = ~wclk;
    always #7 rclk = ~rclk;
    async_fifo #(.DATA_WIDTH(8), .ADDR_WIDTH(3)) dut (
        .wclk(wclk), .wrst_n(wrst_n), .winc(winc), .wdata(wdata), .wfull(wfull),
        .rclk(rclk), .rrst_n(rrst_n), .rinc(rinc), .rdata(rdata), .rempty(rempty)
    );

    initial begin
        $display("TEST reset skew: write domain released before read domain");
        repeat (3) @(negedge wclk);
        wrst_n = 1;
        @(negedge wclk);
        wdata = 8'hA5;
        winc = 1;
        @(negedge wclk);
        winc = 0;
        $display("WRITE data=0xA5 accepted while rrst_n=0");
        repeat (3) begin
            @(negedge rclk);
            if (rempty) stale_cycles = stale_cycles + 1;
            $display("OBSERVE rrst_n=0 unread_data=1 rempty=%0b rdata=0x%02x", rempty, rdata);
        end
        if (stale_cycles == 3)
            $display("EVIDENCE stale rempty=1 for %0d observed read-clock cycles despite pending data", stale_cycles);
        else begin
            $display("ERROR expected stale empty indication was not observed");
            errors = errors + 1;
        end
        rrst_n = 1;
        @(negedge rclk);
        while (rempty) @(negedge rclk);
        rinc = 1;
        #1;
        $display("AFTER_RELEASE rempty=%0b first_data=0x%02x", rempty, rdata);
        if (rdata !== 8'hA5) errors = errors + 1;
        @(negedge rclk);
        rinc = 0;
        if (errors == 0)
            $display("PASS tb_reset_skew reproduction");
        else
            $display("FAIL tb_reset_skew reproduction errors=%0d", errors);
        $finish;
    end
endmodule
