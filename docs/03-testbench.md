# 03 测试平台：主回归、自检参考模型与坑点证据

本工程的三个 testbench 分别回答不同问题：`tb_async_fifo` 验证正常协议下的数据完整性与边界状态；`tb_overflow` 验证写侧违规后到底丢了什么；`tb_reset_skew` 验证复位释放错开时标志和数据各是什么。它们合起来比单纯打印一个 `PASS` 更有说服力，因为输出还保留了写入数量、丢失样本和旧标志持续周期等证据。

运行方式：

```bash
make sim
```

`Makefile` 使用 `iverilog -g2012`，逐个指定顶层模块，编译到 `build/*.vvp` 后用 `vvp` 执行。三个用例使用同一 RTL，但参数、流量和目标不同。

## 一、主回归的时钟与自检模型

`tb/tb_async_fifo.v` 默认实例化 16 深、8 位宽 FIFO：

```verilog
localparam DATA_WIDTH = 8;
localparam ADDR_WIDTH = 4;
localparam DEPTH = 1 << ADDR_WIDTH;
```

两个时钟周期不同：

```verilog
always #5 wclk = ~wclk;
always #7 rclk = ~rclk;
```

在 `timescale 1ns/1ps` 下，`wclk` 每 5 ns 翻转一次，周期 10 ns；`rclk` 每 7 ns 翻转一次，周期 14 ns。它们不是同一个时钟的分频，相位会持续错动，足以让功能仿真反复遇到不同的采样关系。但零延迟 RTL 仿真不能证明真实器件的亚稳态恢复能力，后者仍需要 CDC 与时序签核。

### 参考队列：记录「应该读到什么」

测试平台用一个足够大的数组保存所有成功提交的数据：

```verilog
reg [DATA_WIDTH-1:0] expected [0:8191];
integer writes = 0, reads = 0, errors = 0;
```

`push` 任务只在 `wfull=0` 时发写请求，请求完成后把数据写入参考数组并递增 `writes`：

```verilog
while (wfull) @(negedge wclk);
wdata = data;
winc = 1;
@(negedge wclk);
winc = 0;
expected[writes] = data;
writes = writes + 1;
```

这不是在预测 DUT 内部指针，而是维护协议层面的先进先出参考顺序：第 `n` 次成功写入的数据，应当是第 `n` 次读出的数据。`pop` 同理先等待非空，再使能读取，并在读指针推进前采样当前 `rdata`：

```verilog
while (rempty) @(negedge rclk);
rinc = 1;
#1 value = rdata;
if (value !== expected[reads]) begin
    $display("ERROR read=%0d expected=%0d actual=%0d", reads, expected[reads], value);
    errors = errors + 1;
end
```

`#1` 让采样落在驱动 `rinc` 之后、下一个有效读时钟沿之前；当前 `rbin` 尚未推进，所以采到的是正被消费的队首。比较使用 `!==`，能把未知态 `X` 或高阻态差异也视为错误，避免普通 `!=` 在含未知位时产生不易判断的结果。

每次比对后立即打印读序号、期望值和实际值，比最后只报一个错误总数更容易定位是首数据错、顺序错位还是某次跨域丢项。

### 为什么任务都在负沿驱动

写、读任务主要在 `negedge` 改变 `winc`、`rinc` 和 `wdata`，而 DUT 在 `posedge` 采样。这样激励与采样沿分开，减少同一仿真时刻竞争赋值造成的歧义。它是 testbench 的驱动约定，不是说真实硬件只能用负沿。

## 二、四个阶段分别验证什么

### 阶段 1：fill-to-full，装满并检查满标志

```verilog
for (i = 0; i < DEPTH; i = i + 1) push(i);
repeat (2) @(negedge wclk);
if (!wfull) begin
    $display("ERROR full flag not asserted at capacity");
    errors = errors + 1;
end
```

这一段连续写入 `DEPTH` 个数据，读侧尚未读。它检查三个层面：前 16 次写都被接受、第 16 次完成后 `wfull` 能置位、写指针回到低地址时没有被误判为空。等待两个写负沿后再查标志，避免把任务结束时序与寄存输出更新挤在一起。

这一阶段也覆盖满公式最关键的一次转换：写指针相对读指针领先整圈时，必须报告满。

### 阶段 2：drain-to-empty，读空并检查数据顺序

```verilog
for (i = 0; i < DEPTH; i = i + 1) pop;
repeat (3) @(negedge rclk);
if (!rempty) begin
    $display("ERROR empty flag not asserted after drain");
    errors = errors + 1;
end
```

每次 `pop` 都与 `expected[reads]` 比对，因此这里不仅看 `rempty`，还验证第一阶段写入的 0 到 15 是否按原顺序读出。最后一项消费后，读格雷码追上同步写格雷码，`rempty` 应置位。

如果 FIFO 发生重复读、跳读或首尾颠倒，这一段会给出明确的读序号；如果只验证空标志而不比数据，许多顺序错误会被漏掉。

### 阶段 3：wraparound sequential traffic，反复跨回绕点

```verilog
for (i = 0; i < 4*DEPTH; i = i + 1) begin
    push(8'h40 + i);
    pop;
end
while (reads < writes) pop;
```

16 深队列执行 64 次交替写读，足以让指针多次越过低位地址回绕点。与「只装满再读空一次」相比，它能检查指针在持续运行后是否仍保持一致，以及多一位相位是否被正确维护。

主回归采用同一 `expected` 数组持续记录，不在阶段之间清空存储或复位 DUT。因此前面遗留的指针错误会传播到后面的数据比对中，而不是被一次复位掩盖。

### 阶段 4：concurrent random traffic，异步并发随机流量

进入这一阶段前，读写序号归零，但 DUT 和参考数组都继续存在；此后新的期望数据从数组开头覆盖即可，因为此前数据已全部读出：

```verilog
writes = 0;
reads = 0;
fork
    for (wi = 0; wi < 250; wi = wi + 1) push($random);
    for (ri = 0; ri < 250; ri = ri + 1) pop;
join
```

`fork...join` 让两个循环真正并行推进。写侧遇满等待，读侧遇空等待；250 个随机数据在 10 ns 与 14 ns 两个时钟下交叉传输。这里同时覆盖背压、空满恢复、不同相位采样和多次回绕。

真实日志的总证据是：

```text
PHASE fill-to-full
PHASE drain-to-empty
PHASE wraparound sequential traffic
PHASE concurrent random traffic
STATS writes=250 reads=250 errors=0
PASS tb_async_fifo
```

`writes=250`、`reads=250` 排除了「消费者提前退出所以没遇到错误」，`errors=0` 表示每次数据比对和边界标志检查都通过。最终判定同时要求三个条件：

```verilog
if (errors == 0 && writes == 250 && reads == 250)
    $display("PASS tb_async_fifo");
```

## 三、坑点用例 1：满了还写，丢的是新数据

`tb/tb_overflow.v` 把深度缩到 4：

```verilog
localparam ADDR_WIDTH = 2;
```

然后读侧保持不读，写侧连续尝试 8 次，而且**故意不遵守 `wfull` 背压**。每个尝试周期都记录当前是否被拒绝：

```verilog
wdata = i;
winc = 1;
attempts = attempts + 1;
if (wfull) begin
    rejected = rejected + 1;
    $display("DROP attempt=%0d data=%0d wfull=1", attempts, i);
end else begin
    accepted = accepted + 1;
end
```

前四次写入 0、1、2、3 后队列满。后四次仍拉高 `winc`，RTL 的 `winc && !wfull` 不成立，因此不会写存储，也不会推进写指针。真实输出逐项对应：

```text
DROP attempt=5 data=4 wfull=1
DROP attempt=6 data=5 wfull=1
DROP attempt=7 data=6 wfull=1
DROP attempt=8 data=7 wfull=1
READ index=0 data=0
READ index=1 data=1
READ index=2 data=2
READ index=3 data=3
EVIDENCE attempts=8 accepted=4 rejected=4 received=4 lost=4
LOST_SAMPLES data=4,5,6,7 (new writes discarded; stored data remains intact)
PASS tb_overflow reproduction
```

这组证据排除了两个模糊说法。第一，所谓「溢出」不是覆盖最早的 0、1、2、3，旧数据仍原样读出；第二，丢失的明确是后来试图写入的 4、5、6、7。`accepted=4` 与 `received=4` 也把写侧接收数和读侧收到数对上了。

这里 `PASS` 表示误用复现符合契约，不表示应用可以忽略 `wfull`。若上游没有自己的重试或丢弃记录，这四个样本就在系统层面无声丢失。

## 四、坑点用例 2：复位错开，`rempty` 会保持旧状态

`tb/tb_reset_skew.v` 先让 `wrst_n` 释放，而 `rrst_n` 仍为 0，然后写入一个字节：

```verilog
wdata = 8'hA5;
winc = 1;
@(negedge wclk);
winc = 0;
```

写域已工作，所以这笔写入被接受。读域仍处复位，`rbin` 与 `wgray_rsync2` 保持 0，`rempty` 被复位固定为 1。测试连续观察三个读时钟周期：

```verilog
repeat (3) begin
    @(negedge rclk);
    if (rempty) stale_cycles = stale_cycles + 1;
    $display("OBSERVE rrst_n=0 unread_data=1 rempty=%0b rdata=0x%02x", rempty, rdata);
end
```

真实日志是：

```text
WRITE data=0xA5 accepted while rrst_n=0
OBSERVE rrst_n=0 unread_data=1 rempty=1 rdata=0xa5
OBSERVE rrst_n=0 unread_data=1 rempty=1 rdata=0xa5
OBSERVE rrst_n=0 unread_data=1 rempty=1 rdata=0xa5
EVIDENCE stale rempty=1 for 3 observed read-clock cycles despite pending data
```

这里最容易误读的是 `rdata=0xa5` 与 `rempty=1` 同时存在。因为读地址保持 0，而存储读为组合输出，刚写入地址 0 的 `0xA5` 确实可能出现在 `rdata`；但读域仍复位，接口明确为空，外部不得消费。数据引脚上有值，不等于数据在协议上有效。

释放 `rrst_n` 后，两级同步器把写指针传到读域，`rempty` 撤销，测试再发 `rinc` 并检查首数据：

```text
AFTER_RELEASE rempty=0 first_data=0xa5
PASS tb_reset_skew reproduction
```

因此证据链完整：复位期间标志保持空，数据总线可能已变化；释放后按协议等待非空，首字节仍完好。

## 五、怎样照模板添加定向用例

添加用例时，先写一个能被证伪的行为命题，再选择最少激励。例如「深度 16 时写 15 项不应满，第 16 项后应满」比「再跑一些随机数据」更明确。步骤如下：

1. 在 `tb/` 新建 `tb_<行为>.v`，声明独立顶层模块和 `timescale`。
2. 从 `tb_async_fifo` 复制两个时钟、DUT 实例与负沿驱动方式；需要缩小边界时可像 `tb_overflow` 一样降低 `ADDR_WIDTH`。
3. 给每次输入建立可独立计算的预期，不要让期望值直接复制 DUT 内部 `wbin`、`wgray` 等状态，否则实现与检查器可能犯同一个错。
4. 在关键事件打印输入、标志、序号和实际数据。计数器要区分尝试、接收、读出和错误。
5. 用明确条件输出唯一的 `PASS` 或 `FAIL`，再调用 `$finish`。不要出现条件失败仍打印 `PASS` 的路径。
6. 在 `Makefile` 的 `TBS` 中加入模块名，`make sim` 就会自动编译运行；开发期间可用 `make tb_<行为>` 单独迭代。

适合继续补充的命题包括：满后只读一项，写侧经过同步延迟后恢复；空后只写一项，读侧等待后仅读一次；多种参数下重复随机流量；复位释放附近施加写读请求。每个用例都应写清预期周期关系，避免靠肉眼猜波形。

## 六、为什么 PASS 之外还要打印证据

单个 `PASS` 只能说明检查器最后走到了某个分支，不能说明测试确实覆盖了计划场景。常见假通过包括：激励根本没发出去、读循环提前退出、参考队列没有更新、复现条件从未发生，或者判定条件漏掉了关键计数。

本工程的证据设计有三层：

- **覆盖证据**：四个 `PHASE` 证明流量走到各阶段；`writes=250`、`reads=250` 证明并发循环完成。
- **正确性证据**：`errors=0` 汇总逐数据比对和标志检查，出错时另有 `ERROR` 行定位。
- **现象证据**：overflow 的 `DROP`、`READ`、`lost=4` 和 reset skew 的三次 `OBSERVE`、`AFTER_RELEASE`，让坑点行为可逐行核验。

写新测试时也应保留这三层。尤其是复现 bug 的用例，`PASS` 的意思往往是「bug 的已知行为确实出现了」，只有把证据行与测试目标一起读，才不会误解成系统功能正常。

下一篇：[04-synthesis.md：通用综合能告诉我们什么](04-synthesis.md)。
