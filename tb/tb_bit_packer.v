`timescale 1ns / 1ps

module tb_bit_packer;

    reg clk;
    reg rst_n;
    reg csr_en;
    reg csr_force_flush;
    reg [15:0] csr_chunk_size;
    reg [15:0] delta_in;
    reg [4:0] bit_width;
    reg is_absolute;
    reg valid_in;

    wire [7:0] byte_out;
    wire byte_valid;
    wire chunk_done;

    bit_packer uut (
        .clk(clk),
        .rst_n(rst_n),
        .csr_en(csr_en),
        .csr_force_flush(csr_force_flush),
        .csr_chunk_size(csr_chunk_size),
        .delta_in(delta_in),
        .bit_width(bit_width),
        .is_absolute(is_absolute),
        .valid_in(valid_in),
        .byte_out(byte_out),
        .byte_valid(byte_valid),
        .chunk_done(chunk_done)
    );

    always #5 clk = ~clk;

    integer i;

    initial begin
        $dumpfile("sim/tb_bit_packer.vcd");
        $dumpvars(0, tb_bit_packer);
        clk = 0;
        rst_n = 0;
        csr_en = 0;
        csr_force_flush = 0;
        csr_chunk_size = 8; // Small chunk for sim
        delta_in = 0;
        bit_width = 0;
        is_absolute = 0;
        valid_in = 0;

        #20 rst_n = 1;

        // Feed 8 samples of 1-bit each (value = 1) -> Should pack into 1 byte = 0xFF
        $display("Testing 8x 1-bit samples...");
        for (i = 0; i < 8; i = i + 1) begin
            @(posedge clk);
            delta_in <= 16'd1;
            bit_width <= 5'd1;
            valid_in <= 1;
        end
        
        @(posedge clk);
        valid_in <= 0;

        // Wait to see byte pop out and chunk_done assert
        for (i = 0; i < 5; i = i + 1) begin
            @(posedge clk);
            if (byte_valid) begin
                if (byte_out == 8'hFF) $display("PASS: Packed 8 1-bits into 0xFF");
                else $display("FAIL: Packed byte incorrect: %h", byte_out);
            end
            if (chunk_done) $display("PASS: Chunk done asserted!");
        end

        // Feed 1 sample of 16-bit
        #20;
        $display("Testing 16-bit absolute sample with forced flush...");
        csr_chunk_size <= 64; // bigger chunk

        @(posedge clk);
        delta_in <= 16'hABCD;
        bit_width <= 16;
        is_absolute <= 1;
        valid_in <= 1;
        
        @(posedge clk);
        valid_in <= 0;
        csr_en <= 1;
        csr_force_flush <= 1;
        
        @(posedge clk);
        csr_en <= 0;
        csr_force_flush <= 0;
        
        // Wait and check bytes as they come out
        for (i = 0; i < 4; i = i + 1) begin
            @(posedge clk);
            if (byte_valid) begin
                if (byte_out == 8'hCD) $display("PASS: LSB correct (0xCD)");
                else if (byte_out == 8'hAB) begin
                    if (chunk_done) $display("PASS: MSB correct (0xAB) and chunk flushed");
                    else $display("FAIL: MSB correct but flush missing");
                end
                else $display("FAIL: Unexpected byte: %h", byte_out);
            end
        end

        #30 $finish;
    end

endmodule
