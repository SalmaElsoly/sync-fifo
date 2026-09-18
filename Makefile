# =============================================================================
# sync-fifo - synchronous FIFO in SystemVerilog
#
#   make sim     compile + run the testbench (Icarus Verilog)
#   make wave    open the waveform in GTKWave
#   make lint    static checks with Verilator
#   make synth   synthesise to a gate-level netlist with Yosys, print area
#   make tools   show which tools are installed
#   make clean
# =============================================================================

IVERILOG  ?= iverilog
VVP       ?= vvp
GTKWAVE   ?= gtkwave
VERILATOR ?= verilator
YOSYS     ?= yosys

BUILD := build
RTL   := rtl/sync_fifo.sv
TB    := tb/tb_sync_fifo.sv

# -g2012 selects the SystemVerilog-2012 language level.
IVFLAGS := -g2012 -Wall -Irtl

.PHONY: all sim wave lint synth tools clean

all: sim

$(BUILD):
	@mkdir -p $(BUILD)

# ---- simulation -------------------------------------------------------------

$(BUILD)/tb_sync_fifo.vvp: $(RTL) $(TB) | $(BUILD)
	$(IVERILOG) $(IVFLAGS) -s tb_sync_fifo -o $@ $(RTL) $(TB)

sim: $(BUILD)/tb_sync_fifo.vvp
	@$(VVP) $< | tee $(BUILD)/sim.log
	@grep -q "TEST PASSED" $(BUILD)/sim.log || { echo "==> FAILED"; exit 1; }

# ---- waveform ---------------------------------------------------------------

wave: $(BUILD)/tb_sync_fifo.vcd
	$(GTKWAVE) $< &

$(BUILD)/tb_sync_fifo.vcd: sim

# ---- lint -------------------------------------------------------------------

lint:
	$(VERILATOR) --lint-only -Wall --top-module sync_fifo $(RTL)
	@echo "==> lint clean"

# ---- synthesis --------------------------------------------------------------

synth: | $(BUILD)
	$(YOSYS) -q -s synth/synth.ys
	@echo "==> netlist: $(BUILD)/fifo_netlist.v"
	@cat $(BUILD)/synth_stat.txt

# ---- housekeeping -----------------------------------------------------------

tools:
	@for t in $(IVERILOG) $(VVP) $(VERILATOR) $(YOSYS) $(GTKWAVE); do \
	  printf '  %-12s %s\n' "$$t" "$$(command -v $$t || echo 'NOT INSTALLED')"; \
	done

clean:
	rm -rf $(BUILD)
