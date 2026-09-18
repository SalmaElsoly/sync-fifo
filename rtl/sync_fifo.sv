// -----------------------------------------------------------------------------
// sync_fifo.sv - synchronous (single clock) FIFO buffer
//
// The interesting part of a FIFO is not the memory, it is telling "full" apart
// from "empty". Both conditions have the read and write pointers at the same
// place in the buffer, so a pointer that only counts 0..DEPTH-1 cannot
// distinguish them.
//
// The fix: make each pointer one bit wider than it needs to be. The extra MSB
// counts how many times that pointer has wrapped around.
//
//   empty : pointers identical, including the wrap bit
//   full  : same position in the buffer, but the wrap bits differ
//           (the writer has lapped the reader exactly once)
//
// DEPTH must be a power of two for this trick to work.
// -----------------------------------------------------------------------------
`default_nettype none

module sync_fifo #(
    parameter int WIDTH = 8,
    parameter int DEPTH = 16
) (
    input  logic             clk,
    input  logic             rst,      // synchronous, active high

    // write port
    input  logic             wr_en,
    input  logic [WIDTH-1:0] wr_data,
    output logic             full,

    // read port
    input  logic             rd_en,
    output logic [WIDTH-1:0] rd_data,
    output logic             empty,

    // occupancy, 0..DEPTH
    output logic [$clog2(DEPTH):0] count
);

    localparam int AW = $clog2(DEPTH);

    // Storage. One extra pointer bit beyond AW, as described above.
    logic [WIDTH-1:0] mem [0:DEPTH-1];
    logic [AW:0]      wr_ptr, rd_ptr;

    // A request only takes effect if it is legal. This is what makes the FIFO
    // safe to drive with wr_en/rd_en tied high: overflow and underflow are
    // silently ignored rather than corrupting the pointers.
    wire do_wr = wr_en & ~full;
    wire do_rd = rd_en & ~empty;

    assign empty = (wr_ptr == rd_ptr);
    assign full  = (wr_ptr[AW] != rd_ptr[AW]) &&
                   (wr_ptr[AW-1:0] == rd_ptr[AW-1:0]);
    assign count = wr_ptr - rd_ptr;

    // Combinational read: rd_data always shows the oldest entry, and rd_en pops
    // it. Simple to use and to reason about, and it costs nothing extra here.
    // See the README for the registered-output variant you would want if this
    // had to map onto an FPGA block RAM.
    assign rd_data = mem[rd_ptr[AW-1:0]];

    always_ff @(posedge clk) begin
        if (rst) begin
            wr_ptr <= '0;
            rd_ptr <= '0;
        end else begin
            if (do_wr) wr_ptr <= wr_ptr + 1'b1;
            if (do_rd) rd_ptr <= rd_ptr + 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (do_wr) mem[wr_ptr[AW-1:0]] <= wr_data;
    end

    // Elaboration-time guard: the full/empty logic above is only correct for a
    // power-of-two DEPTH.
    initial begin
        if (DEPTH < 2 || (DEPTH & (DEPTH - 1)) != 0)
            $fatal(1, "sync_fifo: DEPTH must be a power of two >= 2, got %0d", DEPTH);
    end

endmodule

`default_nettype wire
