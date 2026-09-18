// -----------------------------------------------------------------------------
// tb_sync_fifo.sv - self-checking testbench for sync_fifo
//
// Strategy: directed tests for the boundary conditions that FIFOs actually get
// wrong (full, empty, overflow, underflow, wrap-around), then a randomised
// phase that compares the DUT against an independent reference queue.
//
// All stimulus is driven and sampled on the negative clock edge, so nothing
// races the posedge the design uses.
// -----------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module tb_sync_fifo;

    localparam int WIDTH = 8;
    localparam int DEPTH = 16;
    localparam int AW    = $clog2(DEPTH);

    logic             clk = 1'b0;
    logic             rst;
    logic             wr_en, rd_en;
    logic [WIDTH-1:0] wr_data;
    logic [WIDTH-1:0] rd_data;
    logic             full, empty;
    logic [AW:0]      count;

    int errors = 0;
    int checks = 0;

    sync_fifo #(.WIDTH(WIDTH), .DEPTH(DEPTH)) dut (
        .clk(clk), .rst(rst),
        .wr_en(wr_en), .wr_data(wr_data), .full(full),
        .rd_en(rd_en), .rd_data(rd_data), .empty(empty),
        .count(count)
    );

    always #5 clk = ~clk;          // 100 MHz

    // ---- reference model: a plain circular queue, deliberately written in a
    // ---- completely different style from the DUT -----------------------------
    logic [WIDTH-1:0] model [0:1023];
    int mhead = 0, mtail = 0, mcount = 0;

    task model_push(input logic [WIDTH-1:0] d);
        begin
            model[mtail] = d;
            mtail  = (mtail + 1) % 1024;
            mcount = mcount + 1;
        end
    endtask

    task model_pop;
        begin
            mhead  = (mhead + 1) % 1024;
            mcount = mcount - 1;
        end
    endtask

    // ---- checking helpers ----------------------------------------------------
    task expect_eq(input int got, input int exp, input string what);
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("  FAIL %-24s got %0d, expected %0d  (t=%0t)",
                         what, got, exp, $time);
            end
        end
    endtask

    task expect_flags(input logic e_empty, input logic e_full, input string what);
        begin
            checks = checks + 1;
            if (empty !== e_empty || full !== e_full) begin
                errors = errors + 1;
                $display("  FAIL %-24s empty=%0b full=%0b, expected empty=%0b full=%0b  (t=%0t)",
                         what, empty, full, e_empty, e_full, $time);
            end
        end
    endtask

    // ---- bus functional model ------------------------------------------------
    task push(input logic [WIDTH-1:0] d);
        begin
            @(negedge clk);
            wr_en   = 1'b1;
            wr_data = d;
            @(negedge clk);        // the posedge in between commits the write
            wr_en   = 1'b0;
        end
    endtask

    task pop(output logic [WIDTH-1:0] d);
        begin
            @(negedge clk);
            rd_en = 1'b1;
            d     = rd_data;       // combinational read: head is valid now
            @(negedge clk);        // the posedge in between advances rd_ptr
            rd_en = 1'b0;
        end
    endtask

    // ---- test ----------------------------------------------------------------
    logic [WIDTH-1:0] got;
    logic [31:0]      r;
    logic             want_wr, want_rd, will_wr, will_rd;
    logic [WIDTH-1:0] head_now;
    integer i, j;

    initial begin
        $dumpfile("build/tb_sync_fifo.vcd");
        $dumpvars(0, tb_sync_fifo);

        $display("== tb_sync_fifo == WIDTH=%0d DEPTH=%0d", WIDTH, DEPTH);

        // --- 1. reset -------------------------------------------------------
        rst = 1'b1; wr_en = 1'b0; rd_en = 1'b0; wr_data = '0;
        repeat (2) @(negedge clk);
        rst = 1'b0;
        @(negedge clk);
        expect_flags(1'b1, 1'b0, "after reset");
        expect_eq(count, 0, "count after reset");

        // --- 2. underflow on an empty FIFO must be ignored -------------------
        $display("-- underflow --");
        @(negedge clk);
        rd_en = 1'b1;
        @(negedge clk);
        rd_en = 1'b0;
        expect_flags(1'b1, 1'b0, "empty after underflow");
        expect_eq(count, 0, "count after underflow");

        // --- 3. fill to exactly full ----------------------------------------
        $display("-- fill --");
        for (i = 0; i < DEPTH; i = i + 1) begin
            push(8'hA0 + i[7:0]);
            expect_eq(count, i + 1, "count while filling");
        end
        expect_flags(1'b0, 1'b1, "after DEPTH writes");

        // --- 4. overflow must be ignored and must not corrupt data -----------
        $display("-- overflow --");
        @(negedge clk);
        wr_en = 1'b1; wr_data = 8'hEE;
        @(negedge clk);
        wr_en = 1'b0;
        expect_eq(count, DEPTH, "count after overflow");
        expect_flags(1'b0, 1'b1, "still full after overflow");

        // --- 5. drain, checking FIFO ordering --------------------------------
        $display("-- drain --");
        for (i = 0; i < DEPTH; i = i + 1) begin
            pop(got);
            expect_eq(got, 8'hA0 + i[7:0], "FIFO order on drain");
            expect_eq(count, DEPTH - i - 1, "count while draining");
        end
        expect_flags(1'b1, 1'b0, "empty after full drain");

        // --- 6. wrap-around: the pointers are now mid-buffer, so repeat ------
        $display("-- wrap-around --");
        for (j = 0; j < 3; j = j + 1) begin
            for (i = 0; i < DEPTH; i = i + 1) push(8'h10 * j[7:0] + i[7:0]);
            expect_flags(1'b0, 1'b1, "full after wrap fill");
            for (i = 0; i < DEPTH; i = i + 1) begin
                pop(got);
                expect_eq(got, 8'h10 * j[7:0] + i[7:0], "FIFO order after wrap");
            end
            expect_flags(1'b1, 1'b0, "empty after wrap drain");
        end

        // --- 7. randomised read/write against the reference model ------------
        $display("-- randomised (500 cycles) --");
        mhead = 0; mtail = 0; mcount = 0;
        for (i = 0; i < 500; i = i + 1) begin
            @(negedge clk);
            r       = $random;
            want_wr = (r[7:0]   < 8'd160);       // ~63% of cycles
            want_rd = (r[15:8]  < 8'd120);       // ~47% of cycles

            wr_en   = want_wr;
            rd_en   = want_rd;
            wr_data = r[31:24];

            // What the DUT will actually do this cycle, and what it is showing.
            will_wr  = want_wr & ~full;
            will_rd  = want_rd & ~empty;
            head_now = rd_data;

            // Flags must agree with the model before the edge.
            expect_eq(count, mcount, "count vs model");
            expect_eq(empty, (mcount == 0),     "empty vs model");
            expect_eq(full,  (mcount == DEPTH), "full vs model");

            if (will_rd) begin
                checks = checks + 1;
                if (head_now !== model[mhead]) begin
                    errors = errors + 1;
                    $display("  FAIL random read: got 0x%02h, expected 0x%02h (i=%0d)",
                             head_now, model[mhead], i);
                end
            end

            @(negedge clk);                      // the posedge commits both
            if (will_wr) model_push(r[31:24]);
            if (will_rd) model_pop();
        end
        wr_en = 1'b0; rd_en = 1'b0;

        // --- 8. reset while non-empty must clear the FIFO --------------------
        $display("-- reset while occupied --");
        push(8'h5A);
        push(8'h5B);
        @(negedge clk);
        rst = 1'b1;
        @(negedge clk);
        rst = 1'b0;
        @(negedge clk);
        expect_flags(1'b1, 1'b0, "empty after mid-life reset");
        expect_eq(count, 0, "count after mid-life reset");

        $display("== tb_sync_fifo: %0d checks, %0d errors ==", checks, errors);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED");
        $finish;
    end

    // safety net
    initial begin
        #500_000;
        $display("TEST FAILED (timeout)");
        $finish;
    end

endmodule

`default_nettype wire
