`timescale 1ns / 1ps

module tb_fifo;

    reg clk;
    reg rst_n;
    reg csr_en;
    reg csr_flush;
    reg csr_clear_overflow;
    reg [10:0] csr_watermark;
    reg [7:0] wr_data;
    reg wr_en;
    reg rd_en;

    wire [7:0] rd_data;
    wire full;
    wire empty;
    wire almost_full;
    wire almost_empty;
    wire overflow;
    wire [11:0] level;

    fifo_sync #(
        .DATA_WIDTH(8),
        .DEPTH_LOG2(11) // 2048 elements
    ) uut (
        .clk(clk),
        .rst_n(rst_n),
        .csr_en(csr_en),
        .csr_flush(csr_flush),
        .csr_clear_overflow(csr_clear_overflow),
        .csr_watermark(csr_watermark),
        .wr_data(wr_data),
        .wr_en(wr_en),
        .rd_en(rd_en),
        .rd_data(rd_data),
        .full(full),
        .empty(empty),
        .almost_full(almost_full),
        .almost_empty(almost_empty),
        .overflow(overflow),
        .level(level)
    );

    always #5 clk = ~clk;

    integer i;

    initial begin
        $dumpfile("sim/tb_fifo.vcd");
        $dumpvars(0, tb_fifo);
        clk = 0;
        rst_n = 0;
        csr_en = 0;
        csr_flush = 0;
        csr_clear_overflow = 0;
        csr_watermark = 1536; // 75%
        wr_data = 0;
        wr_en = 0;
        rd_en = 0;

        #20 rst_n = 1;

        if (empty) $display("PASS: FIFO is initially empty");

        // Fill FIFO
        $display("Filling FIFO with 2048 bytes...");
        for (i = 0; i < 2048; i = i + 1) begin
            @(posedge clk);
            wr_data <= i[7:0];
            wr_en <= 1;
        end
        @(posedge clk);
        wr_en <= 0;
        
        // Wait one cycle for flags to settle
        @(posedge clk);

        if (full) $display("PASS: FIFO reports full");
        else $display("FAIL: FIFO not full");
        
        if (almost_full) $display("PASS: FIFO reports almost full");

        // Trigger overflow
        @(posedge clk);
        wr_data <= 8'hFF;
        wr_en <= 1;
        @(posedge clk);
        wr_en <= 0;
        @(posedge clk);
        if (overflow) $display("PASS: Overflow flag triggered");
        else $display("FAIL: No overflow detected");

        // Empty FIFO
        $display("Reading 2048 bytes from FIFO...");
        rd_en <= 1;
        for (i = 0; i < 2048; i = i + 1) begin
            @(posedge clk);
            // rd_data is available on the next cycle, so verify it carefully
        end
        rd_en <= 0;
        
        @(posedge clk);
        @(posedge clk); // Give extra cycle for count to reach 0

        if (empty) $display("PASS: FIFO reports empty again");
        else $display("FAIL: FIFO not empty. Level is %d", level);

        #20 $finish;
    end

endmodule
