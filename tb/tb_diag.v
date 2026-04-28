`timescale 1ns / 1ps
module tb_diag;
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
    integer out_count;
    integer tlast_count;

    initial begin
        $dumpfile("sim/tb_diag.vcd");
        $dumpvars(0, tb_diag);
        rst_n = 0; s_axis_tdata = 0; s_axis_tvalid = 0; m_axis_tready = 1;
        out_count = 0; tlast_count = 0;
        repeat (15) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        // Send exactly 128 stable samples = 2 full chunks of 64
        $display("Sending 128 stable samples...");
        for (i = 0; i < 128; i = i + 1) begin
            @(posedge clk);
            s_axis_tdata = 16'd1000 + (i % 3);
            s_axis_tvalid = 1;
        end
        s_axis_tvalid = 0;

        // Wait long enough for full pipeline drain
        // Pipeline latency: ~64 cycles per chunk through bit_packer
        // + CCSDS header emission (~13 cycles) + payload + CRC (2)
        // + FIFO read latency (1 cycle)
        // Need at least 2000 cycles for 2 packets
        repeat (3000) @(posedge clk);

        $display("=== Results ===");
        $display("  Output bytes: %0d", out_count);
        $display("  Packets (tlast): %0d (expect 2)", tlast_count);
        $display("  Overflow: %b", status_overflow);

        // Now test: send 256 more = 4 full chunks
        $display("\nSending 256 more stable samples...");
        out_count = 0; tlast_count = 0;
        for (i = 0; i < 256; i = i + 1) begin
            @(posedge clk);
            s_axis_tdata = 16'd5000 + (i % 5);
            s_axis_tvalid = 1;
        end
        s_axis_tvalid = 0;
        repeat (5000) @(posedge clk);

        $display("=== Results ===");
        $display("  Output bytes: %0d", out_count);
        $display("  Packets (tlast): %0d (expect 4)", tlast_count);
        $display("  Overflow: %b", status_overflow);

        $finish;
    end

    always @(posedge clk) begin
        if (m_axis_tvalid && m_axis_tready) begin
            out_count = out_count + 1;
            if (m_axis_tlast) begin
                tlast_count = tlast_count + 1;
                $display("T=%0t PACKET_END (#%0d), total_bytes=%0d", $time, tlast_count, out_count);
            end
        end
    end

    // Monitor chunk_done
    always @(posedge clk) begin
        if (uut.packer_chunk_done)
            $display("T=%0t CHUNK_DONE sample_count=%0d acc_count=%0d", 
                     $time, uut.u_packer.sample_count, uut.u_packer.acc_count);
    end

    // Monitor CCSDS state transitions
    reg [2:0] prev_state;
    always @(posedge clk) begin
        prev_state <= uut.u_ccsds.state;
        if (uut.u_ccsds.state != prev_state)
            $display("T=%0t CCSDS_STATE %0d -> %0d  pending=%b", 
                     $time, prev_state, uut.u_ccsds.state, uut.u_ccsds.pending_emit);
    end
endmodule
