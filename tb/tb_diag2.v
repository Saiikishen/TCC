`timescale 1ns / 1ps
module tb_diag2;
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
    initial begin
        $dumpfile("sim/tb_diag2.vcd");
        $dumpvars(0, tb_diag2);
        rst_n = 0; s_axis_tdata = 0; s_axis_tvalid = 0; m_axis_tready = 1;
        repeat (15) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        // Send exactly 70 stable samples - should hit 1 chunk at 64
        for (i = 0; i < 70; i = i + 1) begin
            @(posedge clk);
            s_axis_tdata = 16'd1000 + (i % 3);
            s_axis_tvalid = 1;
        end
        s_axis_tvalid = 0;
        repeat (2000) @(posedge clk);
        $finish;
    end

    // Trace bit_packer sample_count every cycle when valid_in
    always @(posedge clk) begin
        if (uut.u_packer.valid_in)
            $display("T=%0t BP valid_in sc=%0d acc=%0d", $time,
                     uut.u_packer.sample_count, uut.u_packer.acc_count);
        if (uut.u_packer.byte_valid)
            $display("T=%0t BP byte=0x%02h chunk_done=%b sc=%0d", $time,
                     uut.u_packer.byte_out, uut.u_packer.chunk_done, 
                     uut.u_packer.sample_count);
        if (uut.u_packer.chunk_done && !uut.u_packer.byte_valid)
            $display("T=%0t BP CHUNK_DONE(no byte) sc=%0d", $time,
                     uut.u_packer.sample_count);
    end
endmodule
