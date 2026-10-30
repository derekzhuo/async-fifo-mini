#!/usr/bin/env bash
set -euo pipefail
out_dir=${1:-build/matrix}
mkdir -p "$out_dir"
summary="$out_dir/matrix-summary.log"
{
  echo "# command: bash scripts/run_matrix.sh $out_dir"
  echo "# date: 2026-10-30"
  echo "# host-toolchain: Icarus Verilog 13.0 / Yosys 0.33 (geek-eda:0.2 docker)"
  echo "# timing: target 100 MHz, period 10 ns; slack = 10 ns - sta longest path delay when available"
  echo "# sta: generic synth cells are unrecognized, so delay/slack are NA; ltp supplies topological path levels"
  echo "depth width cells longest_path_ns slack_ns critical_path_ltp_levels"
} > "$summary"
for addr_width in 2 4 6; do
  depth=$((1 << addr_width))
  for width in 8 32; do
    log="$out_dir/depth-$depth-width-$width.log"
    cmd="read_verilog rtl/async_fifo.v; chparam -set DATA_WIDTH $width -set ADDR_WIDTH $addr_width async_fifo; hierarchy -top async_fifo; synth -top async_fifo; stat; ltp; sta"
    {
      echo "# command: yosys -p \"$cmd\""
      echo "# date: 2026-10-30"
      echo "# host-toolchain: Icarus Verilog 13.0 / Yosys 0.33 (geek-eda:0.2 docker)"
    } > "$log"
    yosys -p "$cmd" >> "$log" 2>&1
    cells=$(grep "Number of cells:" "$log" | tail -n 1 | awk '{print $4}')
    levels=$(grep "Longest topological path" "$log" | tail -n 1 | sed -n 's/.*length=\([0-9][0-9]*\).*/\1/p')
    if grep -q "No timing paths found" "$log"; then
      delay="NA"
      slack="NA"
    else
      delay=$(grep "Longest topological path" "$log" | tail -n 1 | awk '{print $NF}')
      slack=$(awk -v d="$delay" 'BEGIN {printf "%.6f", 10-d}')
    fi
    echo "$depth $width $cells $delay $slack $levels" | tee -a "$summary"
  done
done
