# sync-fifo

A synchronous (single-clock) FIFO buffer in SystemVerilog, with a self-checking
testbench and an open-source simulation, lint and synthesis flow.

```
rtl/sync_fifo.sv       the design       (~60 lines)
tb/tb_sync_fifo.sv     the testbench
synth/synth.ys         Yosys synthesis script
```

## The design

| Port | Dir | Description |
|---|---|---|
| `clk`, `rst` | in | `rst` is synchronous, active high |
| `wr_en`, `wr_data` | in | write request; ignored when `full` |
| `rd_en` | in | read request; ignored when `empty` |
| `rd_data` | out | oldest entry, valid whenever `!empty` |
| `full`, `empty` | out | status flags |
| `count` | out | occupancy, `0..DEPTH` |

Parameters: `WIDTH` (default 8) and `DEPTH` (default 16, **must be a power of
two** — the design `$fatal`s at elaboration otherwise).

### The one idea worth understanding

A FIFO's hard part isn't the memory, it's telling **full** from **empty**. In
both cases the read and write pointers sit at the same place in the buffer, so a
pointer that counts only `0..DEPTH-1` can't distinguish them.

The fix is to make each pointer **one bit wider than it needs to be**. That extra
MSB counts how many times the pointer has wrapped:

```systemverilog
logic [AW:0] wr_ptr, rd_ptr;        // AW = $clog2(DEPTH), so AW+1 bits

assign empty = (wr_ptr == rd_ptr);                  // identical, wrap bit included
assign full  = (wr_ptr[AW] != rd_ptr[AW]) &&        // writer has lapped the reader
               (wr_ptr[AW-1:0] == rd_ptr[AW-1:0]);  // ...at the same slot
assign count = wr_ptr - rd_ptr;                     // subtraction just works
```

`count` comes out free: the wide subtraction wraps correctly by construction.

The other detail is that requests are gated by the status flags:

```systemverilog
wire do_wr = wr_en & ~full;
wire do_rd = rd_en & ~empty;
```

This makes overflow and underflow harmless — the pointers simply don't move —
so the FIFO is safe to drive with `wr_en`/`rd_en` tied high.

### Read latency, and the trade-off

`rd_data` here is **combinational**: it always shows the head, and `rd_en` pops
it. That is simple to use and simple to verify, and it synthesises to a register
file or distributed RAM.

For a large FIFO on an FPGA you would want the read registered instead, so the
storage maps onto a **block RAM**:

```systemverilog
always_ff @(posedge clk)
    if (do_rd) rd_data <= mem[rd_ptr[AW-1:0]];
```

That costs one cycle of read latency, which the consumer has to account for.
Block RAM is far denser than distributed RAM, so past a few hundred bits of
storage it is the right call. Worth knowing that this is a choice, and why.

## Synthesis result

`make synth` at the default `WIDTH=8, DEPTH=16` gives:

```
Number of cells:   383
  $_DFFE_PP_       128      <- the 16 x 8 storage array
  $_SDFFE_PP0P_     10      <- the two 5-bit pointers
  $_SDFF_PP0_        4
  $_MUX_           136      <- read mux + write address decode
  ...
Number of memories:  0
```

Note `memories: 0` and 128 flip-flops: because the read is combinational, the
storage array became **registers, not a RAM**. That is the distributed-vs-block
RAM trade-off described above, visible as a number. Switch to the registered-read
variant and this is what changes.

## Verification

`make sim` runs the testbench, which prints `TEST PASSED` or `TEST FAILED` and
exits non-zero on failure, so it works in CI.

It checks, in order:

1. flags and `count` after reset
2. **underflow** — reading an empty FIFO changes nothing
3. filling to exactly `DEPTH`, watching `count` each step
4. **overflow** — writing a full FIFO is ignored and corrupts no data
5. draining, verifying strict FIFO ordering
6. **wrap-around** — three more fill/drain cycles, since the pointers now start
   mid-buffer and the wrap bit is doing real work
7. 500 cycles of **randomised** concurrent read/write, compared every cycle
   against an independent reference queue written in a deliberately different
   style
8. reset while occupied

Phases 2, 4 and 6 are the ones that matter: overflow, underflow and wrap-around
are where FIFOs actually break, and where an off-by-one in the pointer width
shows up.

All stimulus is driven and sampled on the **negative** clock edge, so nothing
races the positive edge the design clocks on.

## Tools

```bash
sudo apt install -y iverilog verilator yosys gtkwave
make tools          # show what's installed
```

## Use it

```bash
make sim     # compile + run the testbench
make wave    # open the waveform in GTKWave
make lint    # Verilator static checks
make synth   # Yosys -> build/fifo_netlist.v, prints the cell/area report
make clean
```

## Things to try

- Set `DEPTH = 15` and watch the elaboration-time `$fatal` fire.
- Delete the `~full` from `do_wr` and re-run `make sim` — phase 4 should catch
  it immediately.
- Narrow the pointers to `[AW-1:0]` (dropping the wrap bit) and see `full` and
  `empty` become indistinguishable. This is the bug the whole design is built to
  avoid.
- Run `make synth` at `DEPTH = 16` and `DEPTH = 256` and compare cell counts.
- Switch to the registered-read variant above and fix the testbench to match —
  a good exercise in reasoning about latency.
