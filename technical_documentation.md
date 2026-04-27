# 🛰️ FPGA Telemetry Compression Core (TCC) - Technical Documentation

This document provides a detailed technical overview of each module within the Telemetry Compression Core (TCC) pipeline, including their purpose, internal logic, and data flow. The TCC is designed for high-performance, adaptive compression and encryption of aerospace and industrial telemetry.

## System Architecture Data Flow
The TCC processes raw 16-bit sensor data through a fully synchronous 6-stage pipeline:
1. **`edge_analytics.v`**: Analyzes volatility and selects the compression mode.
2. **`quantiser.v`**: Applies lossy shifting if commanded.
3. **`dptc_encoder.v`**: Computes the delta from the previous sample and the minimum bit-width needed.
4. **`bit_packer.v`**: Packs variable-width deltas into a continuous stream of 8-bit bytes.
5. **`ccsds_framer.v`**: Frames the payload into standard CCSDS Space Packets with a header and CRC.
6. **`fifo_sync.v`**: Buffers the packets and interfaces with the AXI-Stream output.

Backpressure (`ready` handshake) propagates backwards from the `bit_packer` to the AXI-Stream input, ensuring zero data loss during high-volatility anomalies.

---

## 1. Edge Analytics Engine (`edge_analytics.v`)

**Purpose**: Real-time signal characterization and adaptive compression mode selection.

### Internal Working:
- **Sliding Window**: Maintains a circular buffer of the last 16 samples (`WINDOW_SIZE = 16`).
- **Mean Calculation**: Continuously computes the moving average using an accumulator (`sum`).
- **Mean Absolute Deviation (MAD)**: Computes the absolute difference of each sample in the window from the mean to gauge signal volatility.
- **Mode Selection Logic**: 
  - `MAD < 50` (Stable/healthy): **Mode 01 (Stable Lossy)**, `q_out = 2`. Normal data is compressed harder to save bandwidth.
  - `50 <= MAD < 200` (Varying): **Mode 00 (Lossless Detail)**, `q_out = 0`. Detail is preserved when the signal starts moving.
  - `MAD >= 200` (Anomaly): **Mode 00 (Lossless Detail)**, `q_out = 0`. Full precision is preserved for anomaly forensics.
- **Backpressure**: Standard skid-less pipeline stage (`assign ready_out = !valid_out || ready_in`).

---

## 2. Quantiser (`quantiser.v`)

**Purpose**: Applies the commanded lossy compression (right-shift) to reduce precision and save bandwidth.

### Internal Working:
- **Arithmetic Shift**: Uses Verilog's signed arithmetic right shift (`>>>`) to preserve the sign bit of the incoming 16-bit sample.
- **Logic**: 
  - If `q_shift == 0`, the sample passes through unchanged (Lossless).
  - If `q_shift > 0`, the bottom `q_shift` bits are discarded. For example, a shift of 2 divides the value by 4, reducing noise jitter.
- **Backpressure**: Standard skid-less pipeline stage.

---

## 3. DPTC Encoder (`dptc_encoder.v`)

**Purpose**: Delta Predictive Transform Coding. It computes the difference between samples to compress the data stream.

### Internal Working:
- **Delta Calculation**: Stores the `prev_sample` and computes the signed 17-bit difference: `diff = sample_in - prev_sample`.
- **Bit-Width Computation**: Uses a combinational helper function (`calc_width`) to determine the absolute minimum number of bits required to transmit the signed delta. 
  - A delta of `0` takes 1 bit.
  - A delta of `1` takes 3 bits.
  - An anomaly delta of `45000` takes 16 bits.
- **Synchronization**: The very first sample after a reset (or forced sync) is transmitted as a 16-bit absolute value to establish a baseline for the receiver.
- **Backpressure**: Standard skid-less pipeline stage.

---

## 4. Bit-Packer (`bit_packer.v`)

**Purpose**: The core compression engine. Packs the variable-width deltas tightly into a continuous stream of 8-bit bytes.

### Internal Working:
- **64-bit Accumulator**: Receives `delta_in` and its corresponding `bit_width`. It dynamically shifts the delta into a 64-bit `accumulator` based on the current `acc_count` (number of bits already stored).
- **Byte Emission**: Every clock cycle, if `acc_count >= 8`, it slices off the bottom 8 bits, emits them to the framer, and right-shifts the accumulator by 8.
- **Chunk Boundaries**: Operates in blocks of 64 samples. After 64 samples, it pads any remaining bits in the accumulator to the nearest byte boundary and asserts `chunk_done`.
- **Backpressure Threshold**: Since it emits 8 bits per cycle but can receive up to 16 bits per cycle (during an anomaly), the accumulator can fill up. When `acc_count > 48`, it asserts `ready_out = 0`, safely stalling the upstream modules until it drains enough bytes.

---

## 5. CCSDS Framer (`ccsds_framer.v`)

**Purpose**: Packages the raw packed bytes into standard CCSDS Space Packets for transmission to ground stations.

### Internal Working:
- **Ping-Pong Buffer**: Contains two 128-byte SRAM buffers (`buf0` and `buf1`). It accepts bytes from the bit-packer continuously into the active write buffer.
- **Packet Construction**: When `chunk_done` fires, the buffers swap. The state machine (FSM) then constructs the packet from the filled buffer:
  1. **Primary Header** (6 bytes): Includes the APID (Application Process ID), Sequence Count, and Packet Length.
  2. **Secondary Header** (5 bytes): Includes a timestamp, the compression Mode, and the Q-Shift value used for the chunk. (Crucial for the receiver to know how to decompress).
  3. **Payload**: The raw bytes dumped from the ping-pong buffer.
  4. **Footer**: A 16-bit CRC-CCITT checksum computed on the fly.
- **8-bit Pointers**: Internal pointers are 8-bit to comfortably handle maximum 128-byte anomaly payloads without integer overflow.

---

## 6. Output FIFO (`fifo_sync.v`)

**Purpose**: Elastic buffering to safely cross between the internal pipeline and the external AXI-Stream interface.

### Internal Working:
- **2048-Byte BRAM**: A deep synchronous FIFO that stores the complete packets.
- **9-Bit Width**: The FIFO is 9 bits wide. It stores the 8-bit data byte and uses the 9th bit to carry the `tlast` (packet end) signal alongside the data.
- **Watermarks**: Asserts a `full` signal back to `tcc_top` when it reaches capacity, allowing the entire pipeline to pause gracefully via backpressure.

---

## 7. Top-Level Integration (`tcc_top.v`)

**Purpose**: Wires all modules together and exposes standard AXI-Stream interfaces.

### Internal Working:
- **Reset Synchronizer**: Safely synchronizes the asynchronous `rst_n` into the clock domain using a 2-flip-flop synchronizer.
- **AXI-Stream Mapping**: Maps the LabVIEW DMA FIFO signals (`s_axis_*` and `m_axis_*`) directly into the pipeline's valid/ready handshake logic.
- **Status Reporting**: Exports key internal metrics (like the current compression mode, FIFO full status, and overflow errors) as simple boolean/byte wires for LabVIEW indicator LEDs.
