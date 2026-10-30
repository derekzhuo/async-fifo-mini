# async-fifo-mini

**对应教程**：https://geek-doc.cn/chip-design/kits/async-fifo.html（上线后生效）

一个用于教学的参数化异步 FIFO 小工程，包含 Cummings 风格格雷码指针、两级触发器跨时钟同步、可综合 RTL、自检 testbench，以及两个常见误用的复现。

## 运行

依赖 Icarus Verilog 13.0 与 Yosys 0.33。在本仓库根目录执行：

```bash
make sim       # 跑功能、overflow、reset skew 三个仿真
make syn       # 默认参数综合，打印 stat 与 sta
make matrix    # 深度 4/16/64 × 位宽 8/32，共 6 档
```

综合矩阵结果写入 `build/matrix/`；`make clean` 删除构建产物。

## 目录

- `rtl/async_fifo.v`：参数化异步 FIFO，教学用途，不是经过硅验证的商用 IP。
- `tb/tb_async_fifo.v`：写满、读空、回绕及并发随机读写自检。
- `tb/tb_overflow.v`：上游忽略 `wfull` 时新写数据丢失的复现。
- `tb/tb_reset_skew.v`：两域复位释放错开时 `rempty` 短暂保持旧状态的复现。
- `scripts/syn.ys`：单档 Yosys 综合脚本。
- `scripts/run_matrix.sh`：六档综合矩阵与汇总。

## 许可

MIT，见 `LICENSE`。
