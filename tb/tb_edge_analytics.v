`timescale 1ns / 1ps

module tb_edge_analytics;

    reg clk;
    reg rst_n;
    reg csr_en;
    reg [1:0] csr_force_mode;
    reg [15:0] csr_t_low;
    reg [15:0] csr_t_high;
    reg [15:0] sample_in;
    reg valid_in;

    wire [15:0] data_out;
    wire valid_out;
    wire [1:0] mode_out;
    wire [3:0] q_out;

    edge_analytics uut (
        .clk(clk),
        .rst_n(rst_n),
        .csr_en(csr_en),
        .csr_force_mode(csr_force_mode),
        .csr_t_low(csr_t_low),
        .csr_t_high(csr_t_high),
        .sample_in(sample_in),
        .valid_in(valid_in),
        .ready_in(1'b1),
        .data_out(data_out),
        .valid_out(valid_out),
        .ready_out(),
        .mode_out(mode_out),
        .q_out(q_out)
    );

    always #5 clk = ~clk;

    integer i;

    initial begin
        $dumpfile("sim/edge_analytics.vcd");
        $dumpvars(0, tb_edge_analytics);

        clk = 0;
        rst_n = 0;
        csr_en = 0;
        csr_force_mode = 0;
        csr_t_low = 50;
        csr_t_high = 200;
        sample_in = 0;
        valid_in = 0;

        #20 rst_n = 1;

        $display("Testing stable signal (bandwidth-saving lossy)...");
        for (i = 0; i < 20; i = i + 1) begin
            @(posedge clk);
            sample_in <= 1000;
            valid_in <= 1;
        end

        @(posedge clk);
        valid_in <= 0;
        #20;
        if (mode_out !== 2'b01 || q_out !== 4'd2) $display("FAIL: Expected Mode 01 / Q=2 (stable lossy)");
        else $display("PASS: Mode 01 / Q=2 correctly selected.");

        $display("Testing moderately volatile signal (lossless detail preserve)...");
        for (i = 0; i < 20; i = i + 1) begin
            @(posedge clk);
            sample_in <= (i % 2 == 0) ? 1000 : 1150; // Moderate swing
            valid_in <= 1;
        end
        
        @(posedge clk);
        valid_in <= 0;
        #20;
        if (mode_out !== 2'b00 || q_out !== 4'd0) $display("FAIL: Expected Mode 00 / Q=0 (varying lossless)");
        else $display("PASS: Mode 00 / Q=0 correctly selected.");

        $display("Testing highly volatile signal (Anomaly)...");
        for (i = 0; i < 20; i = i + 1) begin
            @(posedge clk);
            sample_in <= (i % 2 == 0) ? 1000 : 2000; // Big swing
            valid_in <= 1;
        end
        
        @(posedge clk);
        valid_in <= 0;
        #20;
        if (mode_out !== 2'b00 || q_out !== 4'd0) $display("FAIL: Expected Mode 00 / Q=0 (anomaly lossless)");
        else $display("PASS: Mode 00 / Q=0 anomaly correctly selected.");


        #50 $finish;
    end

endmodule
