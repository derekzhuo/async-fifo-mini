BUILD_DIR ?= build
MATRIX_DIR ?= $(BUILD_DIR)/matrix
TBS := tb_async_fifo tb_overflow tb_reset_skew

.PHONY: all sim syn matrix clean $(TBS)
all: sim

sim:
	@set -e; mkdir -p $(BUILD_DIR); \
	for tb in $(TBS); do \
		echo "=== $$tb ==="; \
		iverilog -g2012 -s $$tb -o $(BUILD_DIR)/$$tb.vvp rtl/async_fifo.v tb/$$tb.v; \
		vvp $(BUILD_DIR)/$$tb.vvp; \
	done

$(TBS):
	@mkdir -p $(BUILD_DIR)
	iverilog -g2012 -s $@ -o $(BUILD_DIR)/$@.vvp rtl/async_fifo.v tb/$@.v
	vvp $(BUILD_DIR)/$@.vvp

syn:
	yosys -s scripts/syn.ys

matrix:
	bash scripts/run_matrix.sh $(MATRIX_DIR)

clean:
	rm -rf $(BUILD_DIR)
