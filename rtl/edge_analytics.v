`timescale 1ns / 1ps

module edge_analytics #(
    parameter WINDOW_SIZE_LOG2 = 4,   // 16 samples window
    parameter DEFAULT_T_LOW = 16'd50,
    parameter DEFAULT_T_HIGH = 16'd200
)(
    input  wire        clk,
    input  wire        rst_n,

    // CSR Interface
    input  wire        csr_en,
    input  wire [1:0]  csr_force_mode,
    input  wire [15:0] csr_t_low,
    input  wire [15:0] csr_t_high,

    // Data Path Interface
    input  wire [15:0] sample_in,
    input  wire        valid_in,
    input  wire        ready_in,

    output reg  [15:0] data_out,
    output reg         valid_out,
    output wire        ready_out,
    output reg  [1:0]  mode_out,
    output reg  [3:0]  q_out
);

    assign ready_out = !valid_out || ready_in;

    localparam WINDOW_SIZE = 1 << WINDOW_SIZE_LOG2;

    // Internal state
    reg [15:0] window [0:WINDOW_SIZE-1];
    reg [WINDOW_SIZE_LOG2-1:0] w_ptr;
    
    // Accumulators for mean calculation
    reg [31:0] sum;
    reg [15:0] current_mean;

    // MAD calculation state
    reg [15:0] current_mad;
    reg        window_seeded;

    integer i;

    // Thresholds
    wire [15:0] t_low = csr_t_low ? csr_t_low : DEFAULT_T_LOW;
    wire [15:0] t_high = csr_t_high ? csr_t_high : DEFAULT_T_HIGH;

    // --- Combinational MAD calculation (separated from clocked block) ---
    // Uses the UPDATED mean (computed combinationally) so MAD tracks the 
    // current window, not the stale one-cycle-old mean.
    wire [31:0] updated_sum = sum + sample_in - window[w_ptr];
    wire [15:0] updated_mean = updated_sum >> WINDOW_SIZE_LOG2;

    reg [31:0] mad_sum_comb;
    integer j;
    always @(*) begin
        mad_sum_comb = 0;
        for (j = 0; j < WINDOW_SIZE; j = j + 1) begin
            if (window[j] > updated_mean)
                mad_sum_comb = mad_sum_comb + (window[j] - updated_mean);
            else
                mad_sum_comb = mad_sum_comb + (updated_mean - window[j]);
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < WINDOW_SIZE; i = i + 1) begin
                window[i] <= 16'd0;
            end
            w_ptr <= 0;
            sum <= 32'd0;
            current_mean <= 16'd0;
            current_mad <= 16'd0;
            window_seeded <= 1'b0;
            
            data_out <= 16'd0;
            valid_out <= 1'b0;
            mode_out <= 2'b00;
            q_out <= 4'd0;
        end else if (ready_out) begin
            valid_out <= 1'b0;
            
            if (valid_in) begin
                valid_out <= 1'b1;

                if (!window_seeded) begin
                    for (i = 0; i < WINDOW_SIZE; i = i + 1) begin
                        window[i] <= sample_in;
                    end
                    w_ptr <= 1;
                    sum <= {16'd0, sample_in} << WINDOW_SIZE_LOG2;
                    current_mean <= sample_in;
                    current_mad <= 16'd0;
                    window_seeded <= 1'b1;

                    if (csr_en) begin
                         mode_out <= csr_force_mode;
                         case (csr_force_mode)
                             2'b00: q_out <= 4'd0;
                             2'b01: q_out <= 4'd2;
                             2'b10: q_out <= 4'd4;
                             default: q_out <= 4'd0;
                         endcase
                    end else begin
                        mode_out <= 2'b01;
                        q_out <= 4'd2;
                    end
                end else begin
                    // Update window and sum
                    sum <= updated_sum;
                    window[w_ptr] <= sample_in;
                    w_ptr <= w_ptr + 1;
                    
                    // Use the combinationally updated mean
                    current_mean <= updated_mean;
                    
                    // MAD uses the combinational result from the always @(*) block
                    current_mad <= mad_sum_comb >> WINDOW_SIZE_LOG2;

                    // Mode decision:
                    // Stable/healthy telemetry is quantised to save bandwidth.
                    // Varying or anomalous telemetry is preserved losslessly.
                    if (csr_en) begin
                         mode_out <= csr_force_mode;
                         case (csr_force_mode)
                             2'b00: q_out <= 4'd0;
                             2'b01: q_out <= 4'd2; // Default light lossy
                             2'b10: q_out <= 4'd4; // Default heavy lossy
                             default: q_out <= 4'd0;
                         endcase
                    end else begin
                        if ((mad_sum_comb >> WINDOW_SIZE_LOG2) < t_low) begin
                            mode_out <= 2'b01; // Stable: lossy compression
                            q_out <= 4'd2;
                        end else if ((mad_sum_comb >> WINDOW_SIZE_LOG2) < t_high) begin
                            mode_out <= 2'b00; // Varying: preserve detail
                            q_out <= 4'd0;
                        end else begin
                            mode_out <= 2'b00; // Anomaly: preserve full precision
                            q_out <= 4'd0; 
                        end
                    end
                end

                data_out <= sample_in;
            end
        end
    end

    integer ea_valid_out_cnt = 0;
    always @(posedge clk) begin
        if (valid_out) ea_valid_out_cnt = ea_valid_out_cnt + 1;
    end

endmodule
