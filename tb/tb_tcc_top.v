`timescale 1ns / 1ps

module tb_tcc_top;

    reg        clk;
    reg        rst_n;
    reg [15:0] s_axis_tdata;
    reg        s_axis_tvalid;
    wire       s_axis_tready;

    wire [7:0] m_axis_tdata;
    wire       m_axis_tvalid;
    reg        m_axis_tready;
    wire       m_axis_tlast;
    reg [15:0] cfg_t_low;
    reg [15:0] cfg_t_high;

    wire [7:0] status_mode;
    wire       status_fifo_full;
    wire       status_overflow;

    tcc_top uut (
        .clk(clk),
        .rst_n(rst_n),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready),
        .m_axis_tlast(m_axis_tlast),
        .cfg_t_low(cfg_t_low),
        .cfg_t_high(cfg_t_high),
        .cfg_force_detail(1'b0),
        .status_mode(status_mode),
        .status_fifo_full(status_fifo_full),
        .status_overflow(status_overflow)
    );

    // 100 MHz clock (10 ns period)
    initial clk = 0;
    always #5 clk = ~clk;

    // Cumulative counters
    integer output_count;
    integer tlast_count;
    integer i;
    reg     test_pass;

    // Snapshot helpers
    integer snap_output, snap_tlast;

    initial begin
        $dumpfile("sim/tb_tcc_top.vcd");
        $dumpvars(0, tb_tcc_top);
        rst_n = 0; s_axis_tdata = 0; s_axis_tvalid = 0; m_axis_tready = 1;
        cfg_t_low = 16'd50; cfg_t_high = 16'd200;
        output_count = 0; tlast_count = 0; test_pass = 1;

        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (5) @(posedge clk);

        $display("=== TCC Top-Level Integration Test ===\n");

        // ---- Test 1: 128 stable samples (2 full chunks) ----
        $display("--- Test 1: 128 stable samples (expect 2 packets, mode 1 stable lossy) ---");
        snap_tlast = tlast_count;
        for (i = 0; i < 128; ) begin
            @(posedge clk);
            s_axis_tdata  = 16'd32768 + (i % 3);
            s_axis_tvalid = 1;
            if (s_axis_tready) i = i + 1;
        end
        @(posedge clk);
        s_axis_tvalid = 0;
        repeat (800) @(posedge clk);

        $display("  Mode:       %0d (expect 1 for stable lossy)", status_mode);
        $display("  Packets:    %0d (expect 2)", tlast_count - snap_tlast);
        $display("  Overflow:   %0b", status_overflow);
        if (tlast_count - snap_tlast < 2) begin
            $display("  ** FAIL: Expected 2 packets"); test_pass = 0;
        end

        // ---- Test 2: 128 volatile samples (2 full chunks) ----
        $display("\n--- Test 2: 128 volatile samples (expect 2 packets, mode 0 lossless detail) ---");
        snap_tlast = tlast_count;
        for (i = 0; i < 128; ) begin
            @(posedge clk);
            s_axis_tdata  = (i % 2 == 0) ? 16'd10000 : 16'd55000;
            s_axis_tvalid = 1;
            if (s_axis_tready) i = i + 1;
        end
        @(posedge clk);
        s_axis_tvalid = 0;
        repeat (800) @(posedge clk);

        $display("  Mode:       %0d (expect 0 for lossless detail)", status_mode);
        $display("  Packets:    %0d (expect 2)", tlast_count - snap_tlast);
        $display("  Overflow:   %0b", status_overflow);
        if (tlast_count - snap_tlast < 2) begin
            $display("  ** FAIL: Expected 2 packets"); test_pass = 0;
        end

        // ---- Test 3: Backpressure ----
        $display("\n--- Test 3: Backpressure (m_axis_tready = 0) ---");
        m_axis_tready = 0;
        for (i = 0; i < 64; ) begin
            @(posedge clk);
            s_axis_tdata  = 16'd40000 + i;
            s_axis_tvalid = 1;
            if (s_axis_tready) i = i + 1;
        end
        @(posedge clk);
        s_axis_tvalid = 0;
        repeat (100) @(posedge clk);
        $display("  s_axis_tready: %0b (expect 1)", s_axis_tready);
        m_axis_tready = 1;
        repeat (800) @(posedge clk);
        $display("  Overflow:      %0b (expect 0)", status_overflow);

        // ---- Test 4: 256 continuous samples (4 chunks) ----
        $display("\n--- Test 4: 256 continuous samples (expect 4 packets) ---");
        snap_tlast = tlast_count;
        snap_output = output_count;
        for (i = 0; i < 256; ) begin
            @(posedge clk);
            s_axis_tdata  = 16'd20000 + (i * 7);
            s_axis_tvalid = 1;
            if (s_axis_tready) i = i + 1;
        end
        @(posedge clk);
        s_axis_tvalid = 0;
        repeat (1500) @(posedge clk);

        $display("  Packets:    %0d (expect 4)", tlast_count - snap_tlast);
        $display("  Bytes out:  %0d", output_count - snap_output);
        $display("  Overflow:   %0b (expect 0)", status_overflow);
        if (tlast_count - snap_tlast < 4) begin
            $display("  ** FAIL: Expected 4 packets"); test_pass = 0;
        end

        // ---- Summary ----
        $display("\n--- Summary ---");
        $display("  Total output bytes: %0d", output_count);
        $display("  Total packets:      %0d", tlast_count);
        $display("  Overflow:           %0b", status_overflow);
        $display("  FIFO Full:          %0b", status_fifo_full);
        $display("  Total tvalid sent:  %0d", total_tvalid_sent);
        $display("  EA valid_out:       %0d", uut.u_edge.ea_valid_out_cnt);

        if (test_pass)
            $display("\n=== ALL TESTS PASSED ===");
        else
            $display("\n=== SOME TESTS FAILED ===");
        $finish;
    end

    integer total_tvalid_sent = 0;

    always @(posedge clk) begin
        if (s_axis_tvalid)
            total_tvalid_sent = total_tvalid_sent + 1;
            
        if (m_axis_tvalid && m_axis_tready) begin
            output_count = output_count + 1;
            if (m_axis_tlast)
                tlast_count = tlast_count + 1;
        end
    end

    always @(posedge clk) begin
        if (uut.packer_chunk_done)
            $display("T=%0t PACKER_CHUNK_DONE", $time);
    end

endmodule
