`timescale 1ns / 1ps

module tb_ccsds_framer;

    reg clk;
    reg rst_n;
    reg csr_en;
    reg [10:0] csr_apid;
    reg [7:0] payload_byte;
    reg payload_valid;
    reg chunk_done;
    reg [1:0] mode;
    reg [3:0] q_out;
    reg [31:0] timestamp;

    wire [7:0] byte_out;
    wire byte_valid;
    wire packet_start;
    wire packet_end;

    ccsds_framer uut (
        .clk(clk),
        .rst_n(rst_n),
        .csr_en(csr_en),
        .csr_apid(csr_apid),
        .payload_byte(payload_byte),
        .payload_valid(payload_valid),
        .chunk_done(chunk_done),
        .mode(mode),
        .q_out(q_out),
        .timestamp(timestamp),
        .byte_out(byte_out),
        .byte_valid(byte_valid),
        .packet_start(packet_start),
        .packet_end(packet_end)
    );

    always #5 clk = ~clk;

    integer i;

    initial begin
        $dumpfile("sim/tb_ccsds_framer.vcd");
        $dumpvars(0, tb_ccsds_framer);
        clk = 0;
        rst_n = 0;
        csr_en = 0;
        csr_apid = 11'h010;
        payload_byte = 0;
        payload_valid = 0;
        chunk_done = 0;
        mode = 2'b10;
        q_out = 4'd4;
        timestamp = 32'hDEADBEEF;

        #20 rst_n = 1;

        // Feed a short chunk of 4 bytes
        $display("Sending 4 payload bytes to framer...");
        @(posedge clk);
        payload_byte <= 8'hAA; payload_valid <= 1; chunk_done <= 0;
        @(posedge clk);
        payload_byte <= 8'hBB; payload_valid <= 1; chunk_done <= 0;
        @(posedge clk);
        payload_byte <= 8'hCC; payload_valid <= 1; chunk_done <= 0;
        @(posedge clk);
        payload_byte <= 8'hDD; payload_valid <= 1; chunk_done <= 1;
        
        @(posedge clk);
        payload_valid <= 0; chunk_done <= 0;

        // Monitor output
        // Total bytes expected: 6 (pri) + 5 (sec) + 4 (payload) + 2 (crc) = 17 bytes
        for (i = 0; i < 25; i = i + 1) begin
            @(posedge clk);
            if (byte_valid) begin
                $display("Time %0t | Byte %02d | Data: %02X | Start: %b | End: %b",
                         $time, i, byte_out, packet_start, packet_end);
            end
        end

        #50 $finish;
    end

endmodule
