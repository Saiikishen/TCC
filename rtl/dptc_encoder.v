`timescale 1ns / 1ps

module dptc_encoder (
    input  wire        clk,
    input  wire        rst_n,

    // CSR Interface
    input  wire        csr_en,
    input  wire        csr_force_reset,
    
    // Data Path Interface
    input  wire [15:0] sample_in,
    input  wire        valid_in,
    input  wire        ready_in,

    output reg  [15:0] delta_out,
    output reg  [4:0]  bit_width,
    output reg         is_absolute,
    output reg         valid_out,
    output wire        ready_out
);

    assign ready_out = !valid_out || ready_in;

    // Internal state
    reg [15:0] prev_sample;
    reg        sync_lost;

    wire signed [16:0] diff = $signed({1'b0, sample_in}) - $signed({1'b0, prev_sample});

    // Helper function to calculate bit width of a signed delta
    function [4:0] calc_width;
        input signed [16:0] d;
        begin
            if (d == 0) calc_width = 1;
            else if (d >= -1 && d <= 0) calc_width = 2; // -1, 0 handled by 2 bits. Wait, 0 is 1 bit. -1 is 2 bits (-1 = 2'b11).
            else if (d >= -2 && d <= 1) calc_width = 3; 
            else if (d >= -4 && d <= 3) calc_width = 4;
            else if (d >= -8 && d <= 7) calc_width = 5;
            else if (d >= -16 && d <= 15) calc_width = 6;
            else if (d >= -32 && d <= 31) calc_width = 7;
            else if (d >= -64 && d <= 63) calc_width = 8;
            else if (d >= -128 && d <= 127) calc_width = 9;
            else if (d >= -256 && d <= 255) calc_width = 10;
            else if (d >= -512 && d <= 511) calc_width = 11;
            else if (d >= -1024 && d <= 1023) calc_width = 12;
            else if (d >= -2048 && d <= 2047) calc_width = 13;
            else if (d >= -4096 && d <= 4095) calc_width = 14;
            else if (d >= -8192 && d <= 8191) calc_width = 15;
            else calc_width = 16;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prev_sample <= 16'd0;
            sync_lost   <= 1'b1;
            delta_out   <= 16'd0;
            bit_width   <= 5'd0;
            is_absolute <= 1'b0;
            valid_out   <= 1'b0;
        end else begin
            if (csr_en && csr_force_reset) begin
                sync_lost <= 1'b1;
            end
            
            if (ready_out) begin
                valid_out <= valid_in;
                if (valid_in) begin
                    prev_sample <= sample_in;
                    
                    if (sync_lost) begin
                        // First sample is sent absolute
                        delta_out   <= sample_in;
                        bit_width   <= 5'd16;
                        is_absolute <= 1'b1;
                        sync_lost   <= 1'b0;
                    end else begin
                        // Compute delta and width
                        delta_out   <= diff[15:0];
                        bit_width   <= calc_width(diff);
                        is_absolute <= 1'b0;
                    end
                end
            end
        end
    end

endmodule
