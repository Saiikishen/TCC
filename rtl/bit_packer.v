`timescale 1ns / 1ps

module bit_packer #(
    parameter MAX_CHUNK_SIZE = 64
)(
    input  wire        clk,
    input  wire        rst_n,

    // CSR Interface
    input  wire        csr_en,
    input  wire        csr_force_flush,
    input  wire [15:0] csr_chunk_size,

    // Data Path Interface
    input  wire [15:0] delta_in,
    input  wire [4:0]  bit_width,
    input  wire        is_absolute,
    input  wire        valid_in,

    output reg  [7:0]  byte_out,
    output reg         byte_valid,
    output reg         chunk_done,
    output wire        ready_out
);

    // Stop accepting data if we are within 16 bits of overflowing
    assign ready_out = (acc_count <= 48);

    // 64-bit accumulator to hold bits temporarily before emitting
    reg [63:0] accumulator;
    reg [6:0]  acc_count; // Number of valid bits in accumulator (up to 64)

    wire [15:0] active_chunk_size = (csr_chunk_size > 0) ? csr_chunk_size : MAX_CHUNK_SIZE;
    reg [15:0] sample_count;
    
    // Chunk-complete flag: set when sample_count reaches active_chunk_size,
    // stays high until all accumulated bits are drained.
    reg        chunk_pending;

    // ---- Shift register to track chunk boundaries alongside accumulator ----
    reg [7:0] chunk_done_tags;

    reg [63:0] masked_delta;
    reg [63:0] next_accumulator;
    reg [6:0]  next_acc_count;
    reg [15:0] next_sample_count;
    reg [7:0]  next_chunk_done_tags;
    
    reg        do_boundary;
    reg        do_emit;
    reg        do_chunk_done;
    reg [7:0]  emit_byte;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            accumulator      <= 64'd0;
            acc_count        <= 7'd0;
            sample_count     <= 16'd0;
            chunk_done_tags  <= 8'd0;
            byte_out         <= 8'd0;
            byte_valid       <= 1'b0;
            chunk_done       <= 1'b0;
        end else begin
            next_accumulator     = accumulator;
            next_acc_count       = acc_count;
            next_sample_count    = sample_count;
            next_chunk_done_tags = chunk_done_tags;
            
            do_boundary          = 1'b0;
            do_emit              = 1'b0;
            do_chunk_done        = 1'b0;
            emit_byte            = 8'd0;

            // Step A: Accept incoming delta if we are ready
            if (valid_in && ready_out) begin
                masked_delta = (64'd0 | delta_in) & ((64'd1 << bit_width) - 64'd1);
                next_accumulator = next_accumulator | (masked_delta << next_acc_count);
                next_acc_count = next_acc_count + bit_width;
                next_sample_count = next_sample_count + 1;
            end

            // Step B: Detect chunk boundary
            if (next_sample_count >= active_chunk_size || 
               (csr_en && csr_force_flush && next_sample_count > 0)) begin
                do_boundary = 1'b1;
            end

            if (do_boundary) begin
                $display("T=%0t [bit_packer] BOUNDARY! next_acc_count=%0d", $time, next_acc_count);
                // Pad to byte boundary
                if (next_acc_count % 8 != 0) begin
                    next_acc_count = next_acc_count + (8 - (next_acc_count % 8));
                    $display("T=%0t [bit_packer] PADDED! new next_acc_count=%0d", $time, next_acc_count);
                end
                // Tag this byte as the end of the chunk
                if (next_acc_count > 0) begin
                    next_chunk_done_tags[(next_acc_count / 8) - 1] = 1'b1;
                end
                next_sample_count = 16'd0;
            end

            // Step C: Emit bytes
            if (next_acc_count >= 8) begin
                emit_byte = next_accumulator[7:0];
                do_chunk_done = next_chunk_done_tags[0];
                do_emit = 1'b1;

                next_accumulator = next_accumulator >> 8;
                next_acc_count = next_acc_count - 8;
                next_chunk_done_tags = next_chunk_done_tags >> 1;
            end

            // Register state
            accumulator      <= next_accumulator;
            acc_count        <= next_acc_count;
            sample_count     <= next_sample_count;
            chunk_done_tags  <= next_chunk_done_tags;
            byte_out         <= emit_byte;
            byte_valid       <= do_emit;
            chunk_done       <= do_chunk_done;
        end
    end

endmodule
