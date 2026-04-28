`timescale 1ns / 1ps

module tb_tcc_matlab_driven;

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
    reg        cfg_force_detail;

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
        .cfg_force_detail(cfg_force_detail),
        .status_mode(status_mode),
        .status_fifo_full(status_fifo_full),
        .status_overflow(status_overflow)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk; // 100 MHz

    reg [1023:0] stim_path;
    reg [1023:0] trace_path;
    reg [1023:0] packet_path;
    reg [1023:0] summary_path;
    reg [1023:0] vcd_path;

    integer stim_fd;
    integer trace_fd;
    integer packet_fd;
    integer summary_fd;

    integer scan_count;
    integer eof_hit;
    integer next_sample_idx;
    integer next_channel_id;
    integer next_sample_word;
    integer next_fault_active;

    integer current_sample_idx;
    integer current_channel_id;
    integer current_fault_active;

    integer cycle;
    integer sent_count;
    integer input_fire_count;
    integer output_byte_count;
    integer packet_count;
    integer packet_byte_index;
    integer drain_cycles;
    integer raw_bytes;
    integer detail_hold_count;

    task set_channel_thresholds;
        input integer channel_id;
        input integer fault_active;
        begin
            if (fault_active) begin
                cfg_t_low  = 16'd0;      // Injected fault: force lossless detail
                cfg_t_high = 16'hFFFF;
            end else begin
                case (channel_id)
                    1: begin
                        cfg_t_low  = 16'd320;  // pressure: tolerate healthy pump ripple
                        cfg_t_high = 16'd900;
                    end
                    2: begin
                        cfg_t_low  = 16'd60;   // flow: normally very steady
                        cfg_t_high = 16'd450;
                    end
                    3: begin
                        cfg_t_low  = 16'd900;  // vibration: healthy motor harmonic is large
                        cfg_t_high = 16'd2400;
                    end
                    default: begin
                        cfg_t_low  = 16'd120;
                        cfg_t_high = 16'd500;
                    end
                endcase
            end
        end
    endtask

    initial begin
        stim_path    = "demo/generated/oilrig_pressure.mem";
        trace_path   = "demo/generated/fpga_trace.csv";
        packet_path  = "demo/generated/fpga_packets.csv";
        summary_path = "demo/generated/fpga_summary.txt";
        vcd_path     = "demo/generated/tb_tcc_matlab_driven.vcd";

        if (!$value$plusargs("STIM=%s", stim_path)) begin end
        if (!$value$plusargs("TRACE=%s", trace_path)) begin end
        if (!$value$plusargs("PACKETS=%s", packet_path)) begin end
        if (!$value$plusargs("SUMMARY=%s", summary_path)) begin end
        if (!$value$plusargs("VCD=%s", vcd_path)) begin end

        stim_fd = $fopen(stim_path, "r");
        if (stim_fd == 0) begin
            $display("ERROR: could not open stimulus file: %0s", stim_path);
            $finish;
        end

        trace_fd = $fopen(trace_path, "w");
        if (trace_fd == 0) begin
            $display("ERROR: could not open trace file: %0s", trace_path);
            $finish;
        end

        packet_fd = $fopen(packet_path, "w");
        if (packet_fd == 0) begin
            $display("ERROR: could not open packet file: %0s", packet_path);
            $finish;
        end

        summary_fd = $fopen(summary_path, "w");
        if (summary_fd == 0) begin
            $display("ERROR: could not open summary file: %0s", summary_path);
            $finish;
        end

        $dumpfile(vcd_path);
        $dumpvars(0, tb_tcc_matlab_driven);

        $fwrite(trace_fd, "cycle,input_fire,sample_index,channel_id,sample_u16,fault_active,");
        $fwrite(trace_fd, "input_ready,mode,q_shift,current_mad,cfg_t_low,cfg_t_high,quantized,dptc_delta,bit_width,is_absolute,");
        $fwrite(trace_fd, "packer_byte_valid,packer_byte,m_axis_tvalid,m_axis_byte,m_axis_tlast,");
        $fwrite(trace_fd, "fifo_level,fifo_full,overflow\n");

        $fwrite(packet_fd, "packet_id,byte_index,cycle,byte_dec,byte_hex,tlast\n");

        rst_n = 1'b0;
        s_axis_tdata = 16'd0;
        s_axis_tvalid = 1'b0;
        m_axis_tready = 1'b1;
        cfg_t_low = 16'd120;
        cfg_t_high = 16'd500;
        cfg_force_detail = 1'b0;

        eof_hit = 0;
        cycle = 0;
        sent_count = 0;
        input_fire_count = 0;
        output_byte_count = 0;
        packet_count = 0;
        packet_byte_index = 0;
        detail_hold_count = 0;
        current_sample_idx = -1;
        current_channel_id = 0;
        current_fault_active = 0;

        repeat (10) @(negedge clk);
        rst_n = 1'b1;
        repeat (4) @(negedge clk);

        $display("=== MATLAB-driven TCC demo simulation ===");
        $display("Stimulus: %0s", stim_path);

        while (!eof_hit) begin
            @(negedge clk);
            if (!s_axis_tvalid || s_axis_tready) begin
                scan_count = $fscanf(stim_fd, "%d %d %d %d\n",
                    next_sample_idx, next_channel_id, next_sample_word, next_fault_active);

                if (scan_count == 4) begin
                    current_sample_idx = next_sample_idx;
                    current_channel_id = next_channel_id;
                    current_fault_active = next_fault_active;
                    if (next_fault_active) begin
                        detail_hold_count = (next_channel_id == 2) ? 768 : 384;
                    end else if (detail_hold_count > 0) begin
                        detail_hold_count = detail_hold_count - 1;
                    end
                    cfg_force_detail = (next_fault_active || detail_hold_count > 0);
                    set_channel_thresholds(next_channel_id, cfg_force_detail);
                    s_axis_tdata = next_sample_word[15:0];
                    s_axis_tvalid = 1'b1;
                    sent_count = sent_count + 1;
                end else begin
                    eof_hit = 1;
                    s_axis_tvalid = 1'b0;
                end
            end
        end

        @(negedge clk);
        s_axis_tvalid = 1'b0;

        drain_cycles = 0;
        while (drain_cycles < 5000) begin
            @(negedge clk);
            drain_cycles = drain_cycles + 1;
        end

        raw_bytes = input_fire_count * 2;
        $display("--- Demo Summary ---");
        $display("Input samples: %0d", input_fire_count);
        $display("Raw bytes:     %0d", raw_bytes);
        $display("Output bytes:  %0d", output_byte_count);
        $display("Packets:       %0d", packet_count);
        $display("Overflow:      %0b", status_overflow);

        $fwrite(summary_fd, "Input samples: %0d\n", input_fire_count);
        $fwrite(summary_fd, "Raw bytes: %0d\n", raw_bytes);
        $fwrite(summary_fd, "Output bytes: %0d\n", output_byte_count);
        $fwrite(summary_fd, "Packets: %0d\n", packet_count);
        if (output_byte_count > 0)
            $fwrite(summary_fd, "Raw/output byte ratio: %0d.%02d\n",
                raw_bytes / output_byte_count,
                ((raw_bytes % output_byte_count) * 100) / output_byte_count);
        else
            $fwrite(summary_fd, "Raw/output byte ratio: undefined\n");
        $fwrite(summary_fd, "FIFO full: %0b\n", status_fifo_full);
        $fwrite(summary_fd, "Overflow: %0b\n", status_overflow);

        $fclose(stim_fd);
        $fclose(trace_fd);
        $fclose(packet_fd);
        $fclose(summary_fd);
        $finish;
    end

    always @(posedge clk) begin
        if (rst_n) begin
            cycle = cycle + 1;

            if (s_axis_tvalid && s_axis_tready)
                input_fire_count = input_fire_count + 1;

            if (m_axis_tvalid && m_axis_tready) begin
                output_byte_count = output_byte_count + 1;
                $fwrite(packet_fd, "%0d,%0d,%0d,%0d,%02x,%0d\n",
                    packet_count, packet_byte_index, cycle,
                    m_axis_tdata, m_axis_tdata, m_axis_tlast);

                if (m_axis_tlast) begin
                    packet_count = packet_count + 1;
                    packet_byte_index = 0;
                end else begin
                    packet_byte_index = packet_byte_index + 1;
                end
            end

            $fwrite(trace_fd,
                "%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                cycle,
                (s_axis_tvalid && s_axis_tready),
                current_sample_idx,
                current_channel_id,
                s_axis_tdata,
                current_fault_active,
                s_axis_tready,
                status_mode,
                uut.ana_q_out,
                uut.u_edge.current_mad,
                cfg_t_low,
                cfg_t_high,
                uut.quant_data_out,
                $signed(uut.dptc_delta_out),
                uut.dptc_bit_width,
                uut.dptc_is_absolute,
                uut.packer_byte_valid,
                uut.packer_byte_out,
                m_axis_tvalid,
                m_axis_tdata,
                m_axis_tlast,
                uut.u_fifo.level,
                status_fifo_full,
                status_overflow);
        end
    end

endmodule
