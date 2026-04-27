`timescale 1ns / 1ps

module fifo_sync #(
    parameter DATA_WIDTH = 8,
    parameter DEPTH_LOG2 = 11 // 2048 elements
)(
    input  wire                  clk,
    input  wire                  rst_n,
    
    // CSR Interface
    input  wire                  csr_en,
    input  wire                  csr_flush,
    input  wire                  csr_clear_overflow,
    input  wire [DEPTH_LOG2-1:0] csr_watermark,

    // Write Interface
    input  wire [DATA_WIDTH-1:0] wr_data,
    input  wire                  wr_en,
    
    // Read Interface
    output reg  [DATA_WIDTH-1:0] rd_data,
    input  wire                  rd_en,
    output reg                   rd_valid,   // Asserted 1 cycle after rd_en when data was available
    
    // Status Flags
    output wire                  full,
    output wire                  empty,
    output wire                  almost_full,
    output wire                  almost_empty,
    output reg                   overflow,
    output wire [DEPTH_LOG2:0]   level
);

    localparam DEPTH = 1 << DEPTH_LOG2;

    // Use a RAM block for storage (Vivado infers Block RAM easily from this pattern)
    reg [DATA_WIDTH-1:0] ram [0:DEPTH-1];
    
    reg [DEPTH_LOG2:0] count;
    reg [DEPTH_LOG2-1:0] wr_ptr;
    reg [DEPTH_LOG2-1:0] rd_ptr;

    wire [DEPTH_LOG2-1:0] active_watermark = (csr_watermark > 0) ? csr_watermark : (DEPTH - (DEPTH/4)); // Default 75%

    assign full = (count == DEPTH);
    assign empty = (count == 0);
    assign almost_full = (count >= active_watermark);
    assign almost_empty = (count <= (DEPTH/4)); // Default 25%
    assign level = count;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            count    <= 0;
            wr_ptr   <= 0;
            rd_ptr   <= 0;
            overflow <= 0;
            rd_data  <= 0;
            rd_valid <= 0;
        end else begin
            rd_valid <= 1'b0;

            if (csr_en && csr_flush) begin
                count  <= 0;
                wr_ptr <= 0;
                rd_ptr <= 0;
            end else begin
                // Handle read
                if (rd_en && !empty) begin
                    rd_data  <= ram[rd_ptr];
                    rd_valid <= 1'b1;
                    rd_ptr   <= rd_ptr + 1;
                end
                
                // Handle write
                if (wr_en) begin
                    if (!full) begin
                        ram[wr_ptr] <= wr_data;
                        wr_ptr <= wr_ptr + 1;
                    end else begin
                        overflow <= 1'b1; // Sticky flag
                    end
                end
                
                // Count update
                case ({wr_en && !full, rd_en && !empty})
                    2'b10: count <= count + 1;
                    2'b01: count <= count - 1;
                    default: count <= count;
                endcase
            end

            // Clear sticky overflow flag
            if (csr_en && csr_clear_overflow) begin
                overflow <= 1'b0;
            end
        end
    end

endmodule
