`timescale 1ns / 1ps
module tb_diag3;
    reg        clk;
    reg        rst_n;
    reg [15:0] s_axis_tdata;
    reg        s_axis_tvalid;
    wire       s_axis_tready;
    wire [7:0] m_axis_tdata;
    wire       m_axis_tvalid;
    reg        m_axis_tready;
    wire       m_axis_tlast;
    wire [7:0] status_mode;
    wire       status_fifo_full;
    wire       status_overflow;

    tcc_top uut (
        .clk(clk), .rst_n(rst_n),
        .s_axis_tdata(s_axis_tdata), .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .m_axis_tdata(m_axis_tdata), .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready), .m_axis_tlast(m_axis_tlast),
        .cfg_t_low(16'd50), .cfg_t_high(16'd200), .cfg_force_detail(1'b0),
        .status_mode(status_mode), .status_fifo_full(status_fifo_full),
        .status_overflow(status_overflow)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    integer i;
    integer out_count, tlast_count;

    initial begin
        $dumpfile("sim/tb_diag3.vcd");
        $dumpvars(0, tb_diag3);
        rst_n = 0; s_axis_tdata = 0; s_axis_tvalid = 0; m_axis_tready = 1;
        out_count = 0; tlast_count = 0;
        repeat (15) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        // Send exactly 128 stable samples = should be 2 full chunks
        for (i = 0; i < 128; i = i + 1) begin
            @(posedge clk);
            s_axis_tdata = 16'd1000 + (i % 3);
            s_axis_tvalid = 1;
        end
        s_axis_tvalid = 0;
        repeat (5000) @(posedge clk);

        $display("=== 128 samples results ===");
        $display("  bytes=%0d  packets=%0d  overflow=%b", out_count, tlast_count, status_overflow);
        $finish;
    end

    always @(posedge clk) begin
        if (m_axis_tvalid && m_axis_tready) begin
            out_count = out_count + 1;
            if (m_axis_tlast) begin
                tlast_count = tlast_count + 1;
                $display("T=%0t PACKET #%0d  total_bytes=%0d", $time, tlast_count, out_count);
            end
        end
    end

    // Track sample count at chunk boundaries and nearby
    always @(posedge clk) begin
        if (uut.u_packer.chunk_done)
            $display("T=%0t CHUNK_DONE sc=%0d acc=%0d", $time,
                     uut.u_packer.sample_count, uut.u_packer.acc_count);
    end

    // Track when sample_count reaches 60+ to see what happens near boundary
    always @(posedge clk) begin
        if (uut.u_packer.valid_in && uut.u_packer.sample_count >= 60)
            $display("T=%0t BP sc=%0d->%0d acc=%0d bw=%0d", $time,
                     uut.u_packer.sample_count, uut.u_packer.next_sample_count,
                     uut.u_packer.acc_count, uut.u_packer.bit_width);
    end
endmodule
