`timescale 1ns / 1ps

module ccsds_framer (
    input  wire        clk,
    input  wire        rst_n,

    // CSR Interface
    input  wire        csr_en,
    input  wire [10:0] csr_apid,
    
    // Data Path Interface
    input  wire [7:0]  payload_byte,
    input  wire        payload_valid,
    input  wire        chunk_done,
    input  wire [1:0]  mode,
    input  wire [3:0]  q_out,
    input  wire [31:0] timestamp,

    // Output Interface
    output reg  [7:0]  byte_out,
    output reg         byte_valid,
    output reg         packet_start,
    output reg         packet_end
);

    // ---------------------------------------------------------------
    // Ping-pong double buffer (128 bytes each).
    // Write buffer accepts payload bytes in ANY FSM state.
    // Emit buffer is read during S_PAYLOAD.
    // Buffers swap on chunk_done.
    // ---------------------------------------------------------------
    reg [7:0] buf0 [0:127];
    reg [7:0] buf1 [0:127];
    reg       wr_buf_sel;           // 0 = write to buf0, 1 = write to buf1
    reg [7:0] wr_ptr;
    reg [7:0] rd_ptr;
    reg [7:0] emit_len;            // Length of the payload in the emit buffer

    // Pending chunk: queued when chunk_done arrives while FSM is busy
    reg       pending_emit;
    reg [7:0] pending_len;
    reg       pending_buf_sel;
    reg [1:0] pending_mode;
    reg [3:0] pending_q;

    // FSM States
    localparam S_IDLE       = 3'd0,
               S_PRI_HDR    = 3'd1,
               S_SEC_HDR    = 3'd2,
               S_PAYLOAD    = 3'd3,
               S_CRC1       = 3'd4,
               S_CRC2       = 3'd5;
               
    reg [2:0] state;
    reg [3:0] hdr_cnt;

    // CCSDS Header Fields
    wire [10:0] apid = csr_en ? csr_apid : 11'h010;
    reg  [13:0] seq_cnt;
    wire [15:0] pkt_data_length = emit_len + 5 - 1; // 5 bytes sec hdr

    // Latched mode/q for the packet being emitted
    reg [1:0] emit_mode;
    reg [3:0] emit_q;

    // CRC-16-CCITT accumulator (0x1021, init 0xFFFF)
    reg [15:0] crc;
    
    function [15:0] next_crc;
        input [15:0] current_crc;
        input [7:0]  data_byte;
        reg [15:0] c;
        reg [7:0]  d;
        integer i;
        begin
            c = current_crc;
            d = data_byte;
            for (i = 0; i < 8; i = i + 1) begin
                if ((c[15] ^ d[7]) == 1'b1)
                    c = (c << 1) ^ 16'h1021;
                else
                    c = c << 1;
                d = d << 1;
            end
            next_crc = c;
        end
    endfunction

    // Read multiplexer for emit buffer
    reg emit_buf_sel;
    wire [7:0] emit_rd_data = emit_buf_sel ? buf1[rd_ptr] : buf0[rd_ptr];

    // Combinational: compute how many bytes are in the current write buffer
    // when chunk_done fires (accounts for simultaneous payload_valid)
    wire [7:0] chunk_len = payload_valid ? (wr_ptr + 1) : wr_ptr;

    reg [7:0] next_byte;
    
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            wr_buf_sel   <= 1'b0;
            emit_buf_sel <= 1'b0;
            wr_ptr       <= 8'd0;
            rd_ptr       <= 8'd0;
            emit_len     <= 8'd0;
            seq_cnt      <= 14'd0;
            crc          <= 16'hFFFF;
            emit_mode    <= 2'b00;
            emit_q       <= 4'd0;
            pending_emit <= 1'b0;
            pending_len  <= 8'd0;
            pending_buf_sel <= 1'b0;
            pending_mode <= 2'b00;
            pending_q    <= 4'd0;
            
            byte_out     <= 8'd0;
            byte_valid   <= 1'b0;
            packet_start <= 1'b0;
            packet_end   <= 1'b0;
            hdr_cnt      <= 4'd0;
        end else begin
            // Defaults
            byte_valid   <= 1'b0;
            packet_start <= 1'b0;
            packet_end   <= 1'b0;

            // ----- Buffer writes: accept in ANY state -----
            if (payload_valid) begin
                if (wr_buf_sel == 1'b0)
                    buf0[wr_ptr] <= payload_byte;
                else
                    buf1[wr_ptr] <= payload_byte;
                wr_ptr <= wr_ptr + 1;
            end

            // ----- Capture chunk_done: queue if busy -----
            if (chunk_done) begin
                if (chunk_len > 0) begin  // Guard: only emit if there's actual payload
                    if (state == S_IDLE && !pending_emit) begin
                        // Start emission immediately
                        emit_len     <= chunk_len;
                        emit_buf_sel <= wr_buf_sel;
                        emit_mode    <= mode;
                        emit_q       <= q_out;
                        wr_buf_sel   <= ~wr_buf_sel;
                        wr_ptr       <= 7'd0;
                        state        <= S_PRI_HDR;
                        hdr_cnt      <= 0;
                        crc          <= 16'hFFFF;
                        rd_ptr       <= 7'd0;
                    end else begin
                        // FSM is busy — queue for later
                        pending_emit     <= 1'b1;
                        pending_len      <= chunk_len;
                        pending_buf_sel  <= wr_buf_sel;
                        pending_mode     <= mode;
                        pending_q        <= q_out;
                        // Swap write buffer now so new data goes to the free buffer
                        wr_buf_sel       <= ~wr_buf_sel;
                        wr_ptr           <= 7'd0;
                    end
                end
                // If chunk_len == 0, ignore the chunk_done (no payload to frame)
            end

            // ----- FSM -----
            case (state)
                S_IDLE: begin
                    // Check for pending chunk
                    if (pending_emit && !chunk_done) begin
                        emit_len     <= pending_len;
                        emit_buf_sel <= pending_buf_sel;
                        emit_mode    <= pending_mode;
                        emit_q       <= pending_q;
                        pending_emit <= 1'b0;
                        state        <= S_PRI_HDR;
                        hdr_cnt      <= 0;
                        crc          <= 16'hFFFF;
                        rd_ptr       <= 7'd0;
                    end
                end

                S_PRI_HDR: begin
                    byte_valid <= 1'b1;
                    hdr_cnt    <= hdr_cnt + 1;
                    if (hdr_cnt == 0) packet_start <= 1'b1;

                    case (hdr_cnt)
                        0: next_byte = {3'b000, 1'b0, 1'b1, apid[10:8]};
                        1: next_byte = apid[7:0]; 
                        2: next_byte = {2'b11, seq_cnt[13:8]};
                        3: next_byte = seq_cnt[7:0];
                        4: next_byte = pkt_data_length[15:8];
                        5: begin
                           next_byte = pkt_data_length[7:0];
                           state     <= S_SEC_HDR;
                           hdr_cnt   <= 0;
                           seq_cnt   <= seq_cnt + 1;
                        end
                        default: next_byte = 8'd0;
                    endcase
                    byte_out <= next_byte;
                    crc      <= next_crc(crc, next_byte);
                end

                S_SEC_HDR: begin
                    byte_valid <= 1'b1;
                    hdr_cnt    <= hdr_cnt + 1;

                    case (hdr_cnt)
                        0: next_byte = timestamp[31:24];
                        1: next_byte = timestamp[23:16];
                        2: next_byte = timestamp[15:8];
                        3: next_byte = timestamp[7:0];
                        4: begin
                           next_byte = {emit_mode, emit_q, 2'b00};
                           state     <= S_PAYLOAD;
                           rd_ptr    <= 0;
                        end
                        default: next_byte = 8'd0;
                    endcase
                    byte_out <= next_byte;
                    crc      <= next_crc(crc, next_byte);
                end

                S_PAYLOAD: begin
                    byte_valid <= 1'b1;
                    
                    next_byte = emit_rd_data;
                    rd_ptr    <= rd_ptr + 1;
                    
                    byte_out <= next_byte;
                    crc      <= next_crc(crc, next_byte);

                    if (rd_ptr == emit_len - 1) begin
                        state  <= S_CRC1;
                    end
                end

                S_CRC1: begin
                    byte_valid <= 1'b1;
                    byte_out   <= crc[15:8];
                    state      <= S_CRC2;
                end
                
                S_CRC2: begin
                    byte_valid <= 1'b1;
                    byte_out   <= crc[7:0];
                    packet_end <= 1'b1;
                    state      <= S_IDLE;
                end
            endcase
        end
    end

endmodule
