`timescale 1ns/1ps

module tcc_top (
    // LabVIEW FPGA clock (driven by CLIP socket)
    input  wire        clk,
    input  wire        rst_n,

    // AXI-Stream Input (from LabVIEW DMA FIFO)
    input  wire [15:0] s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,

    // AXI-Stream Output (to LabVIEW DMA FIFO)
    output wire [7:0]  m_axis_tdata,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast,

    // Edge analytics threshold configuration.
    // Use channel-calibrated MAD thresholds so pressure, flow, and
    // vibration can each define "stable" in their own ADC scale.
    input  wire [15:0] cfg_t_low,
    input  wire [15:0] cfg_t_high,
    input  wire        cfg_force_detail,

    // CSR status outputs (visible to LabVIEW as Indicator wires)
    // Widened to 8 bits for LabVIEW CLIP U8 compatibility
    output wire [7:0]  status_mode,
    output wire        status_fifo_full,
    output wire        status_overflow
);

    // ---------------------------------------------------------------
    // Reset Synchronizer (2-FF) — safe deassertion in clk domain
    // ---------------------------------------------------------------
    reg rst_n_meta, rst_n_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rst_n_meta <= 1'b0;
            rst_n_sync <= 1'b0;
        end else begin
            rst_n_meta <= 1'b1;
            rst_n_sync <= rst_n_meta;
        end
    end

    // --- Internal wires connecting the 7-stage pipeline ---

    // Ready signals for backpressure
    wire edge_ready_out;
    wire quant_ready_out;
    wire dptc_ready_out;
    wire packer_ready_out;

    // Stage 1 -> 2 (Edge Analytics -> Quantiser)
    wire [15:0] ana_data_out;
    wire        ana_valid_out;
    wire [1:0]  ana_mode_out;
    wire [3:0]  ana_q_out;

    // Stage 2 -> 3
    wire [15:0] quant_data_out;
    wire        quant_valid_out;
    wire [1:0]  quant_mode_out;

    // Stage 3 -> 4
    wire [15:0] dptc_delta_out;
    wire [4:0]  dptc_bit_width;
    wire        dptc_is_absolute;
    wire        dptc_valid_out;

    // Stage 4 -> 5
    wire [7:0]  packer_byte_out;
    wire        packer_byte_valid;
    wire        packer_chunk_done;

    // Stage 5 -> 6
    wire [7:0]  ccsds_byte_out;
    wire        ccsds_byte_valid;
    wire        ccsds_packet_end;

    // ASCON (simplified: passthrough for integration test)
    // In full deployment, ASCON buffers 16 bytes then encrypts
    wire [7:0]  ascon_byte_out;
    wire        ascon_byte_valid;
    wire        ascon_tlast;

    // Stage 6 -> FIFO (9-bit wide: {tlast, byte})
    wire        fifo_full_w;
    wire        fifo_empty_w;
    wire        fifo_overflow_w;
    wire [8:0]  fifo_rd_data;
    wire        fifo_rd_valid;
    wire        fifo_rd_en;

    // --- Module Instantiations ---

    edge_analytics #(.WINDOW_SIZE_LOG2(4), .DEFAULT_T_LOW(50), .DEFAULT_T_HIGH(200))
    u_edge (
        .clk(clk), .rst_n(rst_n_sync),
        .sample_in(s_axis_tdata), .valid_in(s_axis_tvalid), .ready_in(quant_ready_out),
        .csr_en(cfg_force_detail), .csr_force_mode(2'b00),
        .csr_t_low(cfg_t_low), .csr_t_high(cfg_t_high),
        .data_out(ana_data_out), .valid_out(ana_valid_out), .ready_out(edge_ready_out),
        .mode_out(ana_mode_out), .q_out(ana_q_out)
    );

    quantiser u_quant (
        .clk(clk), .rst_n(rst_n_sync),
        .data_in(ana_data_out), .q_shift(ana_q_out),
        .mode_in(ana_mode_out), .valid_in(ana_valid_out), .ready_in(dptc_ready_out),
        .data_out(quant_data_out), .mode_out(quant_mode_out),
        .valid_out(quant_valid_out), .ready_out(quant_ready_out)
    );

    dptc_encoder u_dptc (
        .clk(clk), .rst_n(rst_n_sync),
        .sample_in(quant_data_out), .valid_in(quant_valid_out), .ready_in(packer_ready_out),
        .csr_en(1'b0), .csr_force_reset(1'b0),
        .delta_out(dptc_delta_out), .bit_width(dptc_bit_width),
        .is_absolute(dptc_is_absolute), .valid_out(dptc_valid_out), .ready_out(dptc_ready_out)
    );

    bit_packer u_packer (
        .clk(clk), .rst_n(rst_n_sync),
        .delta_in(dptc_delta_out), .bit_width(dptc_bit_width),
        .is_absolute(dptc_is_absolute), .valid_in(dptc_valid_out),
        .csr_en(1'b0), .csr_force_flush(1'b0), .csr_chunk_size(16'd64),
        .byte_out(packer_byte_out), .byte_valid(packer_byte_valid),
        .chunk_done(packer_chunk_done), .ready_out(packer_ready_out)
    );

    ccsds_framer u_ccsds (
        .clk(clk), .rst_n(rst_n_sync),
        .payload_byte(packer_byte_out), .payload_valid(packer_byte_valid),
        .chunk_done(packer_chunk_done),
        .mode(ana_mode_out), .q_out(ana_q_out),
        .timestamp(32'h0), .csr_en(1'b0), .csr_apid(11'h001),
        .byte_out(ccsds_byte_out), .byte_valid(ccsds_byte_valid),
        .packet_start(), .packet_end(ccsds_packet_end)
    );

    // ASCON passthrough (for quick bringup; replace with real ASCON when validated)
    assign ascon_byte_out   = ccsds_byte_out;
    assign ascon_byte_valid = ccsds_byte_valid;
    assign ascon_tlast      = ccsds_packet_end;

    // 9-bit FIFO: {tlast, data_byte} — carries packet boundary through the FIFO
    fifo_sync #(.DATA_WIDTH(9), .DEPTH_LOG2(11))
    u_fifo (
        .clk(clk), .rst_n(rst_n_sync),
        .csr_en(1'b0), .csr_flush(1'b0), .csr_clear_overflow(1'b0),
        .csr_watermark(11'd1536),
        .wr_en(ascon_byte_valid), .wr_data({ascon_tlast, ascon_byte_out}),
        .rd_en(fifo_rd_en), .rd_data(fifo_rd_data),
        .rd_valid(fifo_rd_valid),
        .full(fifo_full_w), .empty(fifo_empty_w),
        .almost_full(), .almost_empty(),
        .overflow(fifo_overflow_w),
        .level()
    );

    // Output AXI-Stream: read from FIFO whenever downstream is ready
    assign fifo_rd_en    = m_axis_tready && !fifo_empty_w;
    assign m_axis_tdata  = fifo_rd_data[7:0];
    assign m_axis_tvalid = fifo_rd_valid;           // Aligned with registered rd_data
    assign m_axis_tlast  = fifo_rd_data[8] && fifo_rd_valid;  // Only valid with data

    // Backpressure: we accept input as long as FIFO isn't full AND the pipeline is ready
    assign s_axis_tready = !fifo_full_w && edge_ready_out;

    // Status outputs visible in LabVIEW (zero-padded to 8 bits for U8 CLIP type)
    assign status_mode      = {6'b0, ana_mode_out};
    assign status_fifo_full = fifo_full_w;
    assign status_overflow  = fifo_overflow_w;

endmodule
