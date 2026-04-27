`timescale 1ns / 1ps

module quantiser (
    input  wire        clk,
    input  wire        rst_n,
    
    // Data in
    input  wire [15:0] data_in,
    input  wire [3:0]  q_shift,
    input  wire [1:0]  mode_in,
    input  wire        valid_in,
    input  wire        ready_in,

    // Data out
    output reg  [15:0] data_out,
    output reg  [1:0]  mode_out,
    output reg         valid_out,
    output wire        ready_out
);

    assign ready_out = !valid_out || ready_in;

    // Perform arithmetic right shift. In Verilog, shifting a signed wire arithmetic right 
    // preserves the sign bit. We cast data_in to signed.
    wire signed [15:0] signed_data = data_in;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            data_out  <= 16'd0;
            mode_out  <= 2'b00;
            valid_out <= 1'b0;
        end else if (ready_out) begin
            valid_out <= valid_in;
            if (valid_in) begin
                mode_out <= mode_in;
                if (q_shift == 0) begin
                    data_out <= data_in; // Lossless bypass
                end else begin
                    data_out <= $unsigned(signed_data >>> q_shift); // Arithmetic right shift
                end
            end
        end
    end

endmodule
