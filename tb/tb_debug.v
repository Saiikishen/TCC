`timescale 1ns / 1ps
module tb_debug;
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
        .cfg_t_low(16'd50), .cfg_t_high(16'd200),
        .status_mode(status_mode), .status_fifo_full(status_fifo_full),
        .status_overflow(status_overflow)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    integer i;
    initial begin
        $dumpfile("sim/tb_debug.vcd");
        $dumpvars(0, tb_debug);
        rst_n = 0; s_axis_tdata = 0; s_axis_tvalid = 0; m_axis_tready = 1;
        repeat (15) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        // Send 140 continuous stable samples
        for (i = 0; i < 140; i = i + 1) begin
            @(posedge clk);
            s_axis_tdata = 16'd1000 + (i % 3);
            s_axis_tvalid = 1;
        end
        s_axis_tvalid = 0;
        repeat (500) @(posedge clk);
        $finish;
    end

    // Monitor bit_packer signals
    always @(posedge clk) begin
        if (uut.packer_chunk_done)
            $display("T=%0t CHUNK_DONE  byte_valid=%b  sample_count_next=%0d", $time,
                     uut.packer_byte_valid, uut.u_packer.sample_count);
        if (uut.packer_byte_valid)
            $display("T=%0t PACKER_BYTE  byte=0x%02h  chunk_done=%b", $time,
                     uut.packer_byte_out, uut.packer_chunk_done);
    end

    // Monitor CCSDS
    always @(posedge clk) begin
        if (uut.ccsds_byte_valid)
            $display("T=%0t CCSDS_BYTE  byte=0x%02h  pkt_end=%b  state=%0d", $time,
                     uut.ccsds_byte_out, uut.u_ccsds.packet_end, uut.u_ccsds.state);
        if (uut.u_ccsds.pending_emit)
            $display("T=%0t CCSDS_PENDING  pending_len=%0d  state=%0d", $time,
                     uut.u_ccsds.pending_len, uut.u_ccsds.state);
    end

    // Monitor output
    always @(posedge clk) begin
        if (m_axis_tvalid && m_axis_tready)
            $display("T=%0t OUTPUT byte=0x%02h tlast=%b", $time, m_axis_tdata, m_axis_tlast);
    end
endmodule
