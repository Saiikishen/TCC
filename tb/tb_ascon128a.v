`timescale 1ns / 1ps

module tb_ascon128a;

    reg clk;
    reg rst_n;
    reg [127:0] key;
    reg [127:0] nonce;
    reg [127:0] plaintext;
    reg pt_valid;

    wire [127:0] ciphertext;
    wire [127:0] tag;
    wire ct_valid;
    wire busy;

    ascon128a_core uut (
        .clk(clk),
        .rst_n(rst_n),
        .key(key),
        .nonce(nonce),
        .plaintext(plaintext),
        .pt_valid(pt_valid),
        .ciphertext(ciphertext),
        .tag(tag),
        .ct_valid(ct_valid),
        .busy(busy)
    );

    always #5 clk = ~clk;

    initial begin
        $dumpfile("sim/tb_ascon128a.vcd");
        $dumpvars(0, tb_ascon128a);
        clk = 0;
        rst_n = 0;
        key = 128'h000102030405060708090A0B0C0D0E0F;
        nonce = 128'h000102030405060708090A0B0C0D0E0F;
        // Padded 4-byte plaintext: 00010203 || 80 || 000000...
        plaintext = 128'h00010203800000000000000000000000;
        pt_valid = 0;

        #20 rst_n = 1;

        @(posedge clk);
        pt_valid <= 1;
        @(posedge clk);
        pt_valid <= 0;

        $display("Waiting for ASCON permutation to complete (approx 30 cycles)...");
        
        wait(ct_valid);
        
        $display("CT  = %h", ciphertext);
        $display("TAG = %h", tag);
        
        $display("Simulation finished. (Check LWC_AEAD_KAT_128_128.txt for exact expected values).");

        #20 $finish;
    end

endmodule
