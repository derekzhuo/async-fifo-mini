// fwft_fifo.v
// FIFO 读出口双变体（可综合）：同一 FWFT（First-Word Fall-Through）内核，
// 只改一个参数 OUT_REG：
//   OUT_REG=0  直出变体：队头组合直连 o_data，读延迟 0，出口无触发器
//   OUT_REG=1  寄存变体：FWFT 内核后串一级 skid buffer（register slice），
//              读延迟 1，ready 反压时输出保持且可吸收 1 个在途 beat
// 存储体：异步读出数组（分布式 RAM 模型），深度 16、位宽 8。
`default_nettype none
module fwft_fifo #(
  parameter integer WIDTH   = 8,
  parameter integer DEPTH   = 16,
  parameter integer OUT_REG = 0
)(
  input  wire             clk,
  input  wire             rst,
  // 写口
  input  wire             wr,
  input  wire [WIDTH-1:0] wdata,
  // 读口（valid/ready，ready=1 表示下游当拍取走）
  input  wire             dst_ready,
  output wire [WIDTH-1:0] o_data,
  output wire             o_valid,
  // 观测：内核队头真正被弹出的拍（供 testbench 计数）
  output wire             pop_dbg,
  output wire             buf_v_dbg
);

  reg [WIDTH-1:0] mem [0:DEPTH-1];
  reg [3:0] wptr, rptr;
  integer   count;

  // 队头组合直出（FWFT）：空态写入走 bypass 支路
  wire head_v = (count != 0) || (wr && count == 0);
  wire [WIDTH-1:0] head_d = (wr && count == 0) ? wdata : mem[rptr];

  // ---------- 输出级 ----------
  reg [WIDTH-1:0] m0d, m1d;
  reg             m0v, m1v;
  wire            s_ready;   // 输出级可以接收内核队头
  wire [WIDTH-1:0] s_data;
  wire            s_valid;
  wire            pop;

  generate
    if (OUT_REG == 0) begin : g_direct
      // 直出：无任何触发器，下游 ready 组合反传回内核 pop
      assign o_data   = head_d;
      assign o_valid  = head_v;
      assign s_ready  = dst_ready;
      assign s_data   = head_d;
      assign s_valid  = head_v;
      assign buf_v_dbg = 1'b0;
    end else begin : g_reg
      // skid buffer：m0 输出寄存器 + m1 备份寄存器
      assign o_data   = m0d;
      assign o_valid  = m0v;
      assign s_ready  = !m1v;
      assign s_data   = head_d;
      assign s_valid  = head_v;
      assign buf_v_dbg = m1v;

      always @(posedge clk) begin
        if (rst) begin
          m0v <= 1'b0; m1v <= 1'b0;
        end else if (dst_ready) begin
          if (m1v) begin
            // 下游恢复：交出 m0，隐藏寄存器 m1 顶上，本拍不接新队头
            m0d <= m1d; m0v <= 1'b1; m1v <= 1'b0;
          end else begin
            // 正常流水：m0 交出并直接接新队头
            m0d <= s_data; m0v <= s_valid;
          end
        end else if (!m0v) begin
          // 窗口空闲：即使下游不取也先把队头预取进 m0
          m0d <= s_data; m0v <= s_valid;
        end else if (!m1v && s_valid) begin
          // 反压：m0 保持不动（下游看到的 beat 不变），新到队头藏入 m1
          m1d <= s_data; m1v <= 1'b1;
        end
      end
    end
  endgenerate

  assign pop     = head_v && s_ready;
  assign pop_dbg = pop;

  integer next_count;
  always @(posedge clk) begin
    if (rst) begin
      wptr  <= 4'd0; rptr <= 4'd0; count <= 0;
    end else begin
      if (wr) mem[wptr] <= wdata;
      // 仅剩 1 项且同拍写入+弹出：新数据沿 bypass 成为新队头，占用仍为 1
      if (pop && wr && count == 1) begin
        rptr  <= wptr;
        count <= 1;
      end else begin
        if (pop) rptr <= rptr + 4'd1;
        if (wr) wptr <= wptr + 4'd1;
        next_count = count;
        if (wr)  next_count = next_count + 1;
        if (pop) next_count = next_count - 1;
        count <= next_count;
      end
    end
  end

endmodule

// fwft_fifo_naive：反面实现——只加一级简单寄存器，ready 不反传回内核，
// 内核每拍只要有队头就弹出。反压（ready=0）时新队头覆盖寄存器，数据丢失。
`default_nettype none
module fwft_fifo_naive #(
  parameter integer WIDTH = 8,
  parameter integer DEPTH = 16
)(
  input  wire             clk,
  input  wire             rst,
  input  wire             wr,
  input  wire [WIDTH-1:0] wdata,
  input  wire             dst_ready,
  output wire [WIDTH-1:0] o_data,
  output wire             o_valid,
  output wire             pop_dbg
);
  reg [WIDTH-1:0] mem [0:DEPTH-1];
  reg [3:0] wptr, rptr;
  integer   count;

  wire head_v = (count != 0) || (wr && count == 0);
  wire [WIDTH-1:0] head_d = (wr && count == 0) ? wdata : mem[rptr];

  reg [WIDTH-1:0] pd;
  reg             pv;
  // 错误点：无视 dst_ready，有队头就弹、寄存器每拍加载
  wire pop = head_v;
  assign o_data  = pd;
  assign o_valid = pv;
  assign pop_dbg = pop;

  always @(posedge clk) begin
    if (rst) begin
      pv <= 1'b0;
    end else begin
      pd <= head_d;
      pv <= head_v;
    end
  end

  integer next_count;
  always @(posedge clk) begin
    if (rst) begin
      wptr  <= 4'd0; rptr <= 4'd0; count <= 0;
    end else begin
      if (wr) mem[wptr] <= wdata;
      if (pop && wr && count == 1) begin
        rptr  <= wptr; count <= 1;
      end else begin
        if (pop) rptr <= rptr + 4'd1;
        if (wr)  wptr <= wptr + 4'd1;
        next_count = count;
        if (wr)  next_count = next_count + 1;
        if (pop) next_count = next_count - 1;
        count <= next_count;
      end
    end
  end
endmodule
`default_nettype wire
