`timescale 1ns / 1ps

module tb_quantiser;
    reg clk;
    reg rst_n;
    reg [15:0] data_in;
    reg [3:0] q_shift;
    reg [1:0] mode_in;
    reg valid_in;

    wire [15:0] data_out;
    wire [1:0] mode_out;
    wire valid_out;

    quantiser uut (
        .clk(clk),
        .rst_n(rst_n),
        .data_in(data_in),
        .q_shift(q_shift),
        .mode_in(mode_in),
        .valid_in(valid_in),
        .data_out(data_out),
        .mode_out(mode_out),
        .valid_out(valid_out)
    );

    always #5 clk = ~clk;

    initial begin
        $dumpfile("sim/tb_quantiser.vcd");
        $dumpvars(0, tb_quantiser);
        clk = 0;
        rst_n = 0;
        data_in = 0;
        q_shift = 0;
        mode_in = 0;
        valid_in = 0;

        #20 rst_n = 1;

        // Test Lossless (Q=0)
        @(posedge clk);
        data_in <= 16'd1000;
        q_shift <= 0;
        valid_in <= 1;
        @(posedge clk);
        valid_in <= 0;
        @(posedge clk);
        if (data_out == 16'd1000) $display("PASS: Q=0 Lossless");
        else $display("FAIL: Q=0 Lossless, got %d", data_out);

        // Test Lossy (Q=2) --> 1000 >> 2 = 250
        @(posedge clk);
        data_in <= 16'd1000;
        q_shift <= 2;
        valid_in <= 1;
        @(posedge clk);
        valid_in <= 0;
        @(posedge clk);
        if (data_out == 16'd250) $display("PASS: Q=2 Shift");
        else $display("FAIL: Q=2 Shift, got %d", data_out);

        // Test Negative Number Arithmetic Shift (16'hFFF0 = -16)
        // -16 >> 2 = -4 (16'hFFFC)
        @(posedge clk);
        data_in <= 16'hFFF0;
        q_shift <= 2;
        valid_in <= 1;
        @(posedge clk);
        valid_in <= 0;
        @(posedge clk);
        if (data_out == 16'hFFFC) $display("PASS: Arithmetic Negative Shift");
        else $display("FAIL: Arithmetic Negative Shift, got %h", data_out);

        #20 $finish;
    end
endmodule
