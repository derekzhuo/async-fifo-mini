# 05 排错指南：从工具报错到 FIFO 异常行为

排异步 FIFO 问题时，先分清故障属于环境、接口使用、参数修改还是跨域假设。仿真跑不起来通常与 RTL 无关；`PASS` 后系统仍丢数据，往往在上游没有遵守满空；改深度后出现边界错误，则要回到指针公式，而不是盲目增加同步级数。

下面按「现象 → 原因 → 处理」组织。执行命令时都应位于仓库根目录，除非特别说明。

## 一、环境与构建问题

### 1. `make: command not found`

**现象**：终端提示找不到 `make`，还没有进入 Verilog 编译。

**原因**：系统没有构建工具，或者当前 shell 的 `PATH` 不包含它。

**处理**：Ubuntu / Debian 安装：

```bash
sudo apt-get update && sudo apt-get install -y make
```

macOS 安装 Xcode Command Line Tools：

```bash
xcode-select --install
```

Windows 建议直接使用 WSL2 的 Ubuntu 环境。安装后重开终端，用 `make --version` 确认命令可见。

### 2. `iverilog: No such file or directory` 或 `vvp: command not found`

**现象**：`make sim` 已启动，但编译或运行阶段失败。

**原因**：Icarus Verilog 没装或安装不完整；`iverilog` 与 `vvp` 通常由同一个软件包提供。

**处理**：macOS 执行：

```bash
brew install icarus-verilog
iverilog -V
vvp -V
```

Ubuntu / Debian 执行：

```bash
sudo apt-get update && sudo apt-get install -y iverilog
iverilog -V
vvp -V
```

如果已安装却仍找不到，检查是否装在另一个环境，例如宿主机与 WSL、宿主机与容器并不共享 `PATH`。本工程已验证的工具版本是 Icarus Verilog 13.0，但教学 RTL 并不依赖冷门的版本特性。

### 3. 仿真正常，`make syn` 提示 `yosys: command not found`

**现象**：`make sim` 能运行，综合目标却失败。

**原因**：Icarus 与 Yosys 是两个独立工具，能仿真不代表已安装综合器。

**处理**：macOS 用 `brew install yosys`，Ubuntu / Debian 用 `sudo apt-get install -y yosys`，再执行：

```bash
yosys -V
make syn
```

只需要学习功能与 testbench 时，可以先不装 Yosys，不影响 `make sim`。

### 4. `docker: command not found`、`Cannot connect to the Docker daemon` 或镜像不存在

**现象**：容器命令无法启动，分别可能提示找不到 Docker、无法连接守护进程，或 `geek-eda:0.2` 不存在。

**原因**：前三者对应未安装、Docker 服务未启动、本地未构建指定镜像。`geek-eda:0.2` 是已验证环境的镜像名，不代表任何机器都能直接从远端拉取。

**处理**：如果只想尽快跑通，改用本机安装 Icarus/Yosys 最省事。如果坚持使用容器，先启动 Docker，再用实际存在的 EDA 镜像替换示例名。运行格式是：

```bash
docker run --rm -v "$PWD:/work" -w /work <你的镜像> make sim
```

`$PWD` 会把当前仓库挂载到容器 `/work`，所以不要从别的目录执行，否则容器看到的是错误源码。Docker Desktop 还需允许访问该宿主机目录。Linux 下若生成的 `build/` 属主影响后续清理，可调整容器用户映射或删除后由本机重建。

### 5. `scripts/run_matrix.sh` 权限或 shell 相关错误

**现象**：直接双击或执行脚本时报权限不足；在极简 shell 下出现 `pipefail` 不支持。

**原因**：脚本需要 Bash，并使用 `set -euo pipefail`；不应假设所有 `/bin/sh` 都支持这些语法。

**处理**：不直接执行文件，统一通过 Makefile 调用：

```bash
make matrix
```

它显式使用 `bash scripts/run_matrix.sh`。Windows 原生 cmd/PowerShell 不是目标环境，请改用 WSL2、macOS 或 Linux。不要为绕过权限而放宽整个仓库的安全设置。

### 6. 仿真打印 `FAIL`，或输出里没有三个 `PASS`

**现象**：`make sim` 返回后不能确认是否成功，或者日志中间有 `ERROR`。

**原因**：三个 testbench 分别判断，任何一个失败都不能被另外两个 `PASS` 抵消；仿真进程退出码也不应替代对日志的检查。

**处理**：保留完整输出，先找第一个 `ERROR` 或 `FAIL`，再看它之前的阶段和读序号。可单独复现：

```bash
make tb_async_fifo
make tb_overflow
make tb_reset_skew
```

主回归必须看到 `STATS writes=250 reads=250 errors=0`；overflow 必须看到 8 次尝试、4 次接收、4 次拒绝、4 次读出；reset skew 必须看到三次旧 `rempty=1` 和释放后的 `first_data=0xa5`。证据不齐时先检查激励是否执行，不要只改最终判定条件让它打印 `PASS`。

## 二、写入、读出与标志使用问题

### 7. 明明还在写，读后却发现新数据丢了

**现象**：上游连续发数据，FIFO 没报错，但下游收到的样本不连续。

**原因**：最常见是 `wfull=1` 时仍拉高 `winc`。当前契约会忽略满时写请求，既不覆盖旧数据，也不缓存到以后。另一个可能是上游只看 `winc` 统计「已写」，没有结合实际 `wfull` 统计成功接收数。

**处理**：写侧每个 `wclk` 周期只在 `winc && !wfull` 时把事务记为成功；满时撤销或保持请求，依据上层协议选择背压、重试或显式丢包。用 `make tb_overflow` 对照真实证据：深度 4 连续写 8 次，只接收 0、1、2、3，丢失 4、5、6、7。

不要通过取消 `wfull` 检查来「修复」，那会让写指针覆盖未读数据，破坏队列核心不变量。

### 8. 空时读到重复值、旧值，或 `rdata` 有数据却仍 `rempty=1`

**现象**：波形上 `rdata` 看似有效，但读出的业务数据重复或无效；复位错开用例中也能看到 `rempty=1` 与 `rdata=0xa5` 同时存在。

**原因**：`rdata` 是存储数组的组合读，没有独立有效寄存器。`rempty=1` 时，地址仍指向某个存储项，总线可以显示旧数据、未初始化数据或刚写入的数据，但协议上都不可消费。

**处理**：只在 `rinc && !rempty` 的 `rclk` 上升沿接收数据。不要给 `rdata` 另外加一个不看 `rempty` 的「数据非零即有效」判断，也不要因总线上出现期望字节就提前读。复位释放后等待 `rempty=0`，再按正常读契约操作。

### 9. 刚读走一项，`wfull` 没立即变低；刚写入，`rempty` 没立即变低

**现象**：对端事件已经发生，本地标志仍保持若干拍，吞吐看似有气泡。

**原因**：对端格雷码指针要经过目的域两级同步，本地看到的是保守的旧视图。满时晚知道「已有空间」、空时晚知道「已有数据」，都是设计的方向安全性，不是功能故障。

**处理**：先按同步延迟理解预期，不要要求跨域标志同拍响应。如果怀疑卡住，检查对端时钟是否运行、对端复位是否一直拉低、指针是否实际推进。提高同步器级数只会增加延迟，不能提高吞吐上限或修复错误握手。

### 10. 把 `wfull` 直接拿到读域，或把 `rempty` 直接拿到写域

**现象**：跨域控制逻辑出现难复现错误，CDC 工具报未同步信号。

**原因**：`wfull` 只属于 `wclk` 域，`rempty` 只属于 `rclk` 域。直接跨域使用会绕开 RTL 已建立的格雷码同步纪律。

**处理**：每个标志只驱动本域控制。若另一侧需要流量信息，应重新设计合法的跨域消息或握手机制，而不是把标志当普通数据随意接入。`winc`、`wdata` 必须稳定于写时钟采样沿，`rinc` 同理只属于读域。

## 三、复位与参数修改问题

### 11. 只拉一侧复位后，数据残留、丢失或队列状态难解释

**现象**：运行中只复位写侧或读侧，恢复后读到旧数据、少数据，或者满空状态不符合业务预期。

**原因**：FIFO 的一致状态由两侧指针和两条同步链共同构成。单侧复位只清本地状态，并不会清空 `mem`，也不会自动让另一域理解「整批事务作废」。写侧先释放、读侧仍复位时，还可能出现 `rempty=1` 但 `rdata` 已显示新字节的暂时现象。

**处理**：系统初始化时两侧都保持复位，再分别同步释放。若产品必须支持运行中单侧清空，应在上层定义完整流程：停止流量、宣布哪些数据作废、让两侧指针重新达到一致状态、再恢复传输，并增加对应定向测试。不能把初始化用例的结论直接外推到任意运行中单侧复位。

### 12. 复位释放附近偶发异常，但 RTL 仿真一直正常

**现象**：硬件上偶发启动失败，降低频率或重新上电后表现变化；普通零延迟仿真无法重现。

**原因**：异步复位可以异步断言，但异步释放可能落入目的触发器的恢复/移除窗口。当前 RTL 没有内置复位释放同步器，两级 Gray 同步器也不负责复位。

**处理**：在系统复位逻辑中为 `wclk`、`rclk` 两域分别实现异步断言、同步释放，检查复位源和时钟在释放时都已稳定。真实器件上运行 CDC/复位检查，不要只依赖功能仿真。

### 13. 把深度改成 10、24 等非 2 幂后，回绕和满空出错

**现象**：只把某个 `DEPTH` 或地址参数改成目标项数，仿真在尾部或回绕时失败。

**原因**：本设计的低位地址自然回绕、Gray 转换和「高两位取反」满判定都以 `DEPTH = 2^ADDR_WIDTH` 为前提。数组大小单独变成非 2 幂，不会让二进制指针在目标深度处自动归零。

**处理**：保持 `ADDR_WIDTH >= 2`，深度只使用 4、8、16、32、64 等 2 幂值。若必须精确支持其他深度，应重新设计指针回绕、编码和满空比较，并补充首尾边界测试；不能只改数组声明。

### 14. 修改 `ADDR_WIDTH` 后，满公式切片或 testbench 参数不一致

**现象**：改参数后编译警告、位宽不匹配，或 DUT 深度与测试循环深度不同。

**原因**：指针位宽是 `ADDR_WIDTH+1`，满公式还使用 `[ADDR_WIDTH:ADDR_WIDTH-1]` 和 `[ADDR_WIDTH-2:0]`。`ADDR_WIDTH` 过小不符合当前切片假设；testbench 也可能有独立参数和实例化覆盖。

**处理**：以主回归为模板，在 testbench 顶部修改局部 `DATA_WIDTH`、`ADDR_WIDTH`，保持 `DEPTH = 1 << ADDR_WIDTH` 和 DUT 参数连接不变。`ADDR_WIDTH` 至少为 2。修改后重点检查写满、读空与多次回绕，再跑综合矩阵观察资源，不要只跑并发随机阶段。

## 四、用 GTKWave 看波形

### 15. 找不到 VCD，或 GTKWave 打开后没有波形

**现象**：`build/` 只有 `.vvp`，没有 `.vcd`；或者 VCD 创建成功但信号列表为空。

**原因**：当前 testbench 没有加入波形转储语句，`vvp` 不会自动保存所有信号。`$dumpvars` 的顶层名也必须与实际 testbench 模块一致。

**处理**：以 `tb/tb_async_fifo.v` 为例，可在模块内增加一个独立初始块：

```verilog
initial begin
    $dumpfile("build/tb_async_fifo.vcd");
    $dumpvars(0, tb_async_fifo);
end
```

从仓库根目录重新运行并打开：

```bash
make tb_async_fifo
gtkwave build/tb_async_fifo.vcd
```

没有 GTKWave 时，macOS 可 `brew install --cask gtkwave`，Ubuntu / Debian 可 `sudo apt-get install -y gtkwave`。若只用无图形界面的容器或远程 shell，先生成 VCD，再把文件放到有桌面环境的机器打开，通常比配置容器显示转发更简单。

### 16. 波形很多，不知道先看哪些信号

**现象**：把所有内部信号一次性加入后，跳变密集，很难判断一次读写是否正确。

**原因**：异步 FIFO 要按域分组观察。把 `wclk` 域事件与 `rclk` 域事件混在一条时间线上，却不看使能和标志采样沿，容易误判。

**处理**：按下面顺序加入并分组：

| 分组 | 建议信号 | 要观察的关系 |
|---|---|---|
| 写接口 | `wclk`、`wrst_n`、`winc`、`wfull`、`wdata` | 仅在 `winc && !wfull` 的写上升沿接收数据 |
| 读接口 | `rclk`、`rrst_n`、`rinc`、`rempty`、`rdata` | 仅在 `rinc && !rempty` 的读上升沿消费当前队首 |
| 写指针 | `wbin`、`wgray`、`wgray_next` | 二进制与 Gray 是否同源更新，低位地址是否自然回绕 |
| 读指针 | `rbin`、`rgray`、`rgray_next` | 最后一次读后是否追上同步写指针 |
| 写域同步 | `rgray_wsync1`、`rgray_wsync2`、`rgray` | 外部读 Gray 经两级后才参与满比较 |
| 读域同步 | `wgray_rsync1`、`wgray_rsync2`、`wgray` | 外部写 Gray 经两级后才参与空比较 |

先用十六进制或二进制看指针，再按数据顺序看 `wdata/rdata`。检查满时，重点看第 `DEPTH` 次成功写入后 `wgray_next` 是否等于同步读 Gray 高两位取反的位型；检查空时，看 `rgray_next` 是否等于 `wgray_rsync2`。不要仅凭 `rdata` 在空时变化就判 bug，也不要要求本地标志与对端指针同拍变化。

排错结束时，回到最小复现：保存触发条件、关键信号和预期/实际数据，再把它固化成定向 testbench。这样修复后不仅能看波形，还能由参考模型和证据行持续防止回归。

返回：[START-HERE.md：复习完整学习路线](../START-HERE.md)；或回到[规格篇](01-spec.md)重新核对行为契约。
