`timescale 1ns / 1ps
module tb_diag5;
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
    integer in_count, ea_count, q_count, dptc_count, bp_count;

    initial begin
        $dumpfile("sim/tb_diag5.vcd");
        $dumpvars(0, tb_diag5);
        rst_n = 0; s_axis_tdata = 0; s_axis_tvalid = 0; m_axis_tready = 1;
        in_count = 0; ea_count = 0; q_count = 0; dptc_count = 0; bp_count = 0;
        repeat (15) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        for (i = 0; i < 128; i = i + 1) begin
            @(posedge clk);
            s_axis_tdata = 16'd1000 + (i % 3);
            s_axis_tvalid = 1;
        end
        s_axis_tvalid = 0;
        repeat (100) @(posedge clk);

        $display("=== Pipeline valid count (128 input) ===");
        $display("  s_axis_tvalid:  %0d", in_count);
        $display("  edge_analytics: %0d", ea_count);
        $display("  quantiser:      %0d", q_count);
        $display("  dptc_encoder:   %0d", dptc_count);
        $display("  bit_packer:     %0d", bp_count);
        $display("  Lost: %0d", in_count - bp_count);
        $finish;
    end

    always @(posedge clk) begin
        if (s_axis_tvalid && s_axis_tready) in_count = in_count + 1;
        if (uut.ana_valid_out) ea_count = ea_count + 1;
        if (uut.quant_valid_out) q_count = q_count + 1;
        if (uut.dptc_valid_out) dptc_count = dptc_count + 1;
        if (uut.u_packer.valid_in) bp_count = bp_count + 1;
    end
endmodule
