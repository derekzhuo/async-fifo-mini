# 从这里开始：先跑通，再读懂异步 FIFO

这个工程用一个可综合、可自检的最小实现，把异步 FIFO 最重要的几件事串起来：二进制指针在本域累加，格雷码指针跨时钟域传递，满与空分别在写、读时钟域判断。三个 testbench 不只检查正常读写，还主动复现「满了继续写」和「两侧复位错开」两个容易误判的现象。

建议按「跑仿真 → 看规格 → 读设计 → 看验证与综合」的顺序学习。不要一上来只背满判定公式；知道每个信号属于哪个时钟域，公式才有意义。

## 1. 准备环境

最直接的方式是安装 Icarus Verilog；只有需要综合时才再安装 Yosys。macOS 可执行：

```bash
brew install icarus-verilog yosys
```

Ubuntu / Debian 可执行：

```bash
sudo apt-get update && sudo apt-get install -y iverilog yosys make
```

如果本机已有 Docker，也可以把工具链关进容器。假设本地镜像 `geek-eda:0.2` 已包含 Icarus Verilog 13.0 与 Yosys 0.33，在仓库根目录运行：

```bash
docker run --rm -v "$PWD:/work" -w /work geek-eda:0.2 make sim
```

这里的镜像名只是本工程已验证环境的名字，不是 Docker Hub 上保证存在的公共镜像。没有这个镜像时，用上面的本机安装方式最省事。Windows 用户可在 WSL2 的 Ubuntu 环境中执行相同命令。

## 2. 一次跑完三个仿真

在包含 `Makefile` 的仓库根目录执行：

```bash
make sim
```

`make` 会依次编译并运行 `tb_async_fifo`、`tb_overflow`、`tb_reset_skew`。输出很长时，先抓下面三条总结果：

```text
PASS tb_async_fifo
PASS tb_overflow reproduction
PASS tb_reset_skew reproduction
```

三个 `PASS` 的含义并不相同。第一条表示主回归完成了写满、读空、回绕与并发随机读写，最后统计应为：

```text
STATS writes=250 reads=250 errors=0
```

第二条表示「写满后上游仍然写」的误用已被稳定复现：深度为 4 时，8 次写尝试只接收 4 个，后来的 4、5、6、7 被丢弃。第三条表示写侧先释放复位时，读侧的 `rempty` 会暂时保留旧状态，但读侧释放后仍能读到完整的首数据 `0xA5`。后两条不是在宣告数据丢失或旧标志是合理用法，而是在验证接口边界与可观察行为。

只想单独运行某个用例时：

```bash
make tb_async_fifo
make tb_overflow
make tb_reset_skew
```

编译生成的 `.vvp` 文件位于 `build/`。这些是可重新生成的临时产物，不需要手工编辑。

## 3. 按顺序读完整教程

1. [规格与行为契约](docs/01-spec.md)：先弄清每个端口属于哪个域、一次读写在什么沿发生，以及满和空时哪些操作会被忽略。
2. [设计原理与 RTL 逐段拆解](docs/02-design.md)：核心篇。理解格雷码、多一位指针、满判定公式、两级同步和存储体推断。
3. [测试平台与证据解读](docs/03-testbench.md)：看参考队列怎样自检，学习三个用例各自证明了什么、没有证明什么。
4. [综合方法与结果分析](docs/04-synthesis.md)：运行 Yosys，读懂面积与拓扑路径数据，并理解通用流程为何不能给纳秒时序结论。
5. [常见故障排查](docs/05-troubleshooting.md)：遇到工具、接口、复位、参数或波形问题时，按「现象 → 原因 → 处理」定位。

## 4. 第一次修改从哪里入手

最安全的练习是只改 `DATA_WIDTH`，例如把 `tb/tb_async_fifo.v` 中的两个相关局部参数之一改为新值时，要同时保持 testbench 与 DUT 的参数连接一致。当前 testbench 已经把局部参数传给 DUT，因此改下面这一处即可改变数据位宽：

```verilog
localparam DATA_WIDTH = 8;
```

接着改 `ADDR_WIDTH` 可以观察深度如何按 `DEPTH = 1 << ADDR_WIDTH` 变化。注意深度必须是 2 的幂：这是指针回绕和满判定成立的前提，不是一个可以随意填成 10、100 的普通容量参数。

改完先跑 `make sim`，再跑 `make syn` 或 `make matrix` 对比资源。若准备修改指针、同步器或满空逻辑，请先读完[设计原理](docs/02-design.md)，再增加能证明新行为的定向测试；不要只凭原有 `PASS` 推断任意改动都安全。

下一篇：[01-spec.md：规格与行为契约](docs/01-spec.md)。
