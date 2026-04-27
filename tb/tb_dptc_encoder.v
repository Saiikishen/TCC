`timescale 1ns / 1ps

module tb_dptc_encoder;

    reg clk;
    reg rst_n;
    reg csr_en;
    reg csr_force_reset;
    reg [15:0] sample_in;
    reg valid_in;

    wire [15:0] delta_out;
    wire [4:0] bit_width;
    wire is_absolute;
    wire valid_out;

    dptc_encoder uut (
        .clk(clk),
        .rst_n(rst_n),
        .csr_en(csr_en),
        .csr_force_reset(csr_force_reset),
        .sample_in(sample_in),
        .valid_in(valid_in),
        .ready_in(1'b1),
        .delta_out(delta_out),
        .bit_width(bit_width),
        .is_absolute(is_absolute),
        .valid_out(valid_out),
        .ready_out()
    );

    always #5 clk = ~clk;

    initial begin
        $dumpfile("sim/tb_dptc_encoder.vcd");
        $dumpvars(0, tb_dptc_encoder);
        clk = 0;
        rst_n = 0;
        csr_en = 0;
        csr_force_reset = 0;
        sample_in = 0;
        valid_in = 0;

        #20 rst_n = 1;

        // Sample 1: Absolute
        @(posedge clk);
        sample_in <= 16'd1000;
        valid_in <= 1;
        @(posedge clk);
        valid_in <= 0;
        @(posedge clk);
        if (delta_out == 16'd1000 && is_absolute == 1'b1 && bit_width == 16) 
            $display("PASS: First sample is absolute");
        else 
            $display("FAIL: First sample not absolute");

        // Sample 2: Delta = +1 
        @(posedge clk);
        sample_in <= 16'd1001; 
        valid_in <= 1;
        @(posedge clk);
        valid_in <= 0;
        @(posedge clk);
        if (delta_out == 16'd1 && bit_width == 3 && is_absolute == 0) // diff=1 fits in 3 bits (sign + magnitude) -> Wait, 1 fits in 3 bits: 001. No wait, 1 fits in 3 bits [-2, 1] Wait, 1 fits in 3 bits. Let's check calc_width. 
            $display("PASS: Delta +1 width %d", bit_width);
        else 
            $display("FAIL: Delta +1 wrong, got %h w=%d", delta_out, bit_width);

        // Sample 3: Delta = -3
        @(posedge clk);
        sample_in <= 16'd998; 
        valid_in <= 1;
        @(posedge clk);
        valid_in <= 0;
        @(posedge clk);
        if (delta_out == 16'hFFFD && bit_width == 4 && is_absolute == 0) // diff=-3 fits in 4 bits [-4..3]
            $display("PASS: Delta -3 width 4 (val=%h)", delta_out);
        else 
            $display("FAIL: Delta -3 wrong, got %h w=%d", delta_out, bit_width);

        // Force reset
        @(posedge clk);
        csr_en <= 1;
        csr_force_reset <= 1;
        @(posedge clk);
        csr_en <= 0;
        csr_force_reset <= 0;
        
        // Sample 4: Absolute again
        @(posedge clk);
        sample_in <= 16'd500; 
        valid_in <= 1;
        @(posedge clk);
        valid_in <= 0;
        @(posedge clk);
        if (is_absolute == 1'b1 && delta_out == 16'd500)
            $display("PASS: Re-sync triggered absolute sample");
        else
            $display("FAIL: Re-sync failed");

        #20 $finish;
    end

endmodule
