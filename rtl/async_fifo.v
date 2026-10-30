module async_fifo #(
    parameter DATA_WIDTH = 8,
    parameter ADDR_WIDTH = 4
) (
    input  wire                  wclk,
    input  wire                  wrst_n,
    input  wire                  winc,
    input  wire [DATA_WIDTH-1:0] wdata,
    output reg                   wfull,
    input  wire                  rclk,
    input  wire                  rrst_n,
    input  wire                  rinc,
    output wire [DATA_WIDTH-1:0] rdata,
    output reg                   rempty
);
    localparam DEPTH = 1 << ADDR_WIDTH;

    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    reg [ADDR_WIDTH:0] wbin, wgray, rbin, rgray;
    reg [ADDR_WIDTH:0] wgray_rsync1, wgray_rsync2;
    reg [ADDR_WIDTH:0] rgray_wsync1, rgray_wsync2;

    wire [ADDR_WIDTH:0] wbin_next = wbin + (winc & ~wfull);
    wire [ADDR_WIDTH:0] rbin_next = rbin + (rinc & ~rempty);
    wire [ADDR_WIDTH:0] wgray_next = (wbin_next >> 1) ^ wbin_next;
    wire [ADDR_WIDTH:0] rgray_next = (rbin_next >> 1) ^ rbin_next;

    assign rdata = mem[rbin[ADDR_WIDTH-1:0]];

    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n)
            wfull <= 0;
        else
            wfull <= (wgray_next == {~rgray_wsync2[ADDR_WIDTH:ADDR_WIDTH-1],
                                     rgray_wsync2[ADDR_WIDTH-2:0]});
    end

    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n)
            rempty <= 1;
        else
            rempty <= (rgray_next == wgray_rsync2);
    end

    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            wbin <= 0;
            wgray <= 0;
        end else begin
            wbin <= wbin_next;
            wgray <= wgray_next;
            if (winc && !wfull)
                mem[wbin[ADDR_WIDTH-1:0]] <= wdata;
        end
    end

    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            rbin <= 0;
            rgray <= 0;
        end else begin
            rbin <= rbin_next;
            rgray <= rgray_next;
        end
    end

    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n)
            {rgray_wsync2, rgray_wsync1} <= 0;
        else
            {rgray_wsync2, rgray_wsync1} <= {rgray_wsync1, rgray};
    end

    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n)
            {wgray_rsync2, wgray_rsync1} <= 0;
        else
            {wgray_rsync2, wgray_rsync1} <= {wgray_rsync1, wgray};
    end
endmodule
