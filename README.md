# 🛰️ FPGA Telemetry Compression Core (TCC)

A high-performance, adaptive compression and encryption pipeline designed for FPGA-based aerospace and industrial telemetry. This repository provides a modular, fully synchronous Verilog-2001 IP core capable of ingesting raw 16-bit sensor data, applying adaptive lossy/lossless compression, framing it into standard CCSDS Space Packets, and encrypting it using the NIST Lightweight Cryptography standard — **ASCON-128a**.

The TCC is designed as a **drop-in SoC IP core** with standard AXI-Stream / AXI-Lite interfaces, enabling integration into any FPGA or ASIC fabric alongside ARM, RISC-V, or other host processors.

---


## Table of Contents

- [System Architecture Overview](#-system-architecture-overview)
- [Full Pipeline Diagram](#-full-pipeline-diagram)
- [Module 1 — Edge Analytics Engine](#1-edge-analytics-engine)
- [Module 2 — Quantiser](#2-quantiser-lossy-compression-stage)
- [Module 3 — DPTC Encoder](#3-dptc-encoder-delta-predictive-transform-coding)
- [Module 4 — Bit-Packer](#4-bit-packer)
- [Module 5 — CCSDS Framer](#5-ccsds-framer)
- [Module 6 — ASCON-128a Encryption Core](#6-ascon-128a-encryption-core)
- [Module 7 — FIFO Buffer](#7-fifo-buffer-rate-matching)
- [RV32E Supervisor Core](#-rv32e-supervisor-core)
- [ARM Controller Interaction](#-arm-controller-interaction)
- [SoC IP Integration Architecture](#-soc-ip-integration-architecture)
- [Data Width Evolution](#-data-width-evolution-through-the-pipeline)
- [FPGA Resource Utilisation](#-fpga-resource-utilisation)
- [Repository Structure](#-repository-structure)
- [Simulation & Verification](#-simulation--verification)
- [Deployment Targets](#-deployment-targets)

---

## 🏗️ System Architecture Overview

The TCC is a **real-time streaming telemetry processor**. At its core, it is a seven-stage hardware pipeline that processes one 16-bit sensor sample per clock cycle, compresses it adaptively, wraps it in standard telemetry packets, encrypts it with authenticated encryption, and buffers it for transmission.

The entire system consists of three architectural layers:

### Layer 1 — Hardware Data Plane (Streaming Pipeline)
Seven Verilog modules connected in a cascade. Data flows forward one sample per clock cycle with `valid` handshakes. No stalls, no backpressure inside the core pipeline. This is the fast path — raw sensor data enters, encrypted CCSDS packets exit.

### Layer 2 — Software Control Plane (RV32E Supervisor)
An embedded 32-bit RISC-V processor (RV32E variant with 16 registers) that runs firmware from a 4 KB instruction ROM. It does **not** touch the data path. Instead, it reads status registers and writes control registers on every pipeline module via a memory-mapped CSR bus. This allows runtime reconfiguration (e.g., changing compression thresholds, rotating encryption keys, adjusting baud rates) without resynthesising the FPGA bitstream.

### Layer 3 — External Host Interface (ARM / SoC CPU)
When the TCC is deployed inside a larger SoC (e.g., Xilinx Zynq, NI sbRIO), the host ARM processor communicates with the TCC through standard **AXI-Lite** control registers and **AXI-Stream** data ports. The ARM can override the RV32E's configuration, inject sensor data via DMA, and read telemetry status. This is detailed in the [ARM Controller Interaction](#-arm-controller-interaction) section.

---

## 🔄 Full Pipeline Diagram

```
                         ┌────────────────────────────────────────────────────────────────┐
                         │                     TCC IP CORE                                │
                         │                                                                │
   Raw 16-bit            │  ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐     │
   Sensor Data ─────────►│  │   Edge   │──►│ Quantiser│──►│   DPTC   │──►│   Bit    │     │
   (valid/ready)         │  │ Analytics│   │          │   │ Encoder  │   │  Packer  │     │
                         │  │  Engine  │   │ Q-shift  │   │  Delta   │   │  64-bit  │     │
                         │  └──────────┘   └──────────┘   └──────────┘   └────┬─────┘     │
                         │   MAD-based       Arithmetic     Compute diff      │           │
                         │   mode select     right-shift    & min bit-width   │           │
                         │                                                     │          │
                         │  ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌────▼─────┐     │
                         │  │  Output  │◄──│   FIFO   │◄──│ ASCON    │◄──│  CCSDS   │     │
   Encrypted ◄───────────│  │  (UART/  │   │  2048-B  │   │ 128a    │   │  Framer   │     │
   Packets               │  │  AXI-S)  │   │  BRAM    │   │ AEAD    │   │  + CRC    │     │
                         │  └──────────┘   └──────────┘   └──────────┘   └──────────┘     │
                         │                                                                │
                         │  ════════════════════ CSR Bus ═══════════════════════════════  │
                         │                         ▲                                      │
                         │                    ┌────┴────┐                                 │
                         │                    │  RV32E  │ ◄──── 4 KB IROM + 2 KB DRAM     │
                         │                    │  CPU    │                                 │
                         │                    └────┬────┘                                 │
                         │                         │                                      │
                         │           AXI-Lite ◄────┤────► IRQ[7:0]                        │
                         │           (from ARM)    │       (to ARM NVIC / RISC-V PLIC)    │
                         └─────────────────────────┼──────────────────────────────────────┘
                                                   │
                                            Host ARM / SoC CPU
```

All seven pipeline modules share a common `clk` and active-low `rst_n`. Data transfers occur on the rising edge of `clk` when the upstream `valid` signal is asserted.

---

## 📦 Detailed Module Specifications

---

### 1. Edge Analytics Engine

**Source:** [`rtl/edge_analytics.v`](rtl/edge_analytics.v) — 119 lines  
**Purpose:** Real-time signal characterisation and adaptive compression mode selection.

#### What It Does

The Edge Analytics Engine monitors the statistical volatility of the incoming sensor signal using a **sliding-window Mean Absolute Deviation (MAD)** calculation. Based on the computed MAD, it classifies the signal into one of three modes and assigns a corresponding quantisation shift value:

| Condition | Mode | Q Value | Effect |
|---|---|---|---|
| `MAD < T_low` (default 50) | `01` - Stable Lossy | `2` | Healthy/stable data is quantised to save bandwidth |
| `T_low <= MAD < T_high` (default 200) | `00` - Lossless Detail | `0` | Varying data is preserved without precision loss |
| `MAD >= T_high` | `00` - Lossless Detail | `0` | Anomaly detected; full precision preserved for forensics |

#### How It Works Internally

1. **Sliding Window Buffer:** Maintains a register-based circular buffer of `N` recent samples (default `N = 16`, configurable via `WINDOW_SIZE_LOG2` parameter).

2. **Running Sum / Mean:** Keeps a 32-bit running sum. On each new sample, the oldest sample in the window is subtracted and the new sample is added:
   ```
   sum <= sum + sample_in - window[w_ptr]
   current_mean <= sum >> WINDOW_SIZE_LOG2   (division by N via bit-shift)
   ```

3. **MAD Calculation:** Iterates over all `N` window entries, computing `|window[i] − mean|` for each, accumulating into `mad_sum`, then dividing by `N`:
   ```
   current_mad <= mad_sum >> WINDOW_SIZE_LOG2
   ```
   > **Implementation Note:** The MAD is computed using the *previous* cycle's mean to avoid a combinational dependency loop. In a production design, this would be pipelined across multiple cycles. The current implementation uses a combinational `for` loop that synthesises into parallel comparators and adders.

4. **Mode Decision Logic:** The computed `current_mad` is compared against two programmable thresholds (`t_low`, `t_high`). The thresholds can be overridden at runtime via CSR inputs from the RV32E or the host ARM.

5. **CSR Override:** When `csr_en` is asserted, the engine ignores the computed MAD and uses the `csr_force_mode` value directly — allowing the supervisor to lock the compression mode during debugging or calibration.

#### Interface Signals

| Signal | Direction | Width | Description |
|---|---|---|---|
| `clk` | Input | 1 | System clock |
| `rst_n` | Input | 1 | Active-low reset |
| `sample_in` | Input | 16 | Raw input sample |
| `valid_in` | Input | 1 | Input valid strobe |
| `csr_en` | Input | 1 | Force-mode override enable |
| `csr_force_mode` | Input | 2 | Forced mode value (when `csr_en = 1`) |
| `csr_t_low` | Input | 16 | Lower MAD threshold |
| `csr_t_high` | Input | 16 | Upper MAD threshold |
| `data_out` | Output | 16 | Passed-through sample (1-cycle latency) |
| `valid_out` | Output | 1 | Output valid strobe |
| `mode_out` | Output | 2 | Selected compression mode |
| `q_out` | Output | 4 | Quantisation shift amount |

#### Parameters

| Parameter | Default | Description |
|---|---|---|
| `WINDOW_SIZE_LOG2` | `4` | log₂ of the sliding window size (4 → 16 samples) |
| `DEFAULT_T_LOW` | `50` | Default lower MAD threshold |
| `DEFAULT_T_HIGH` | `200` | Default upper MAD threshold |

#### Resource Estimate
~350–600 LUTs, 0 BRAM, 0 DSP

---

### 2. Quantiser (Lossy Compression Stage)

**Source:** [`rtl/quantiser.v`](rtl/quantiser.v) — 42 lines  
**Purpose:** Reduces sample precision by discarding LSBs when the signal is volatile enough to tolerate precision loss.

#### What It Does

Performs a **signed arithmetic right-shift** on the input sample by `Q` bit positions. In lossless mode (`Q = 0`), the sample passes through unchanged. In lossy modes (`Q = 2` or `Q = 6`), the lower bits are discarded, reducing the dynamic range of subsequent deltas and improving compression.

#### How It Works Internally

```verilog
wire signed [15:0] signed_data = data_in;

if (q_shift == 0)
    data_out <= data_in;                             // Lossless bypass
else
    data_out <= $unsigned(signed_data >>> q_shift);   // Arithmetic right shift
```

The Verilog `>>>` operator preserves the sign bit during the shift, so negative values remain negative. The `$unsigned()` cast converts the result back to unsigned for the downstream pipeline.

#### Interface Signals

| Signal | Direction | Width | Description |
|---|---|---|---|
| `data_in` | Input | 16 | Sample from Edge Analytics |
| `q_shift` | Input | 4 | Shift amount (0–15) from Edge Analytics |
| `mode_in` | Input | 2 | Compression mode (passed through) |
| `valid_in` | Input | 1 | Input valid |
| `data_out` | Output | 16 | Quantised sample |
| `mode_out` | Output | 2 | Mode (passed through to DPTC) |
| `valid_out` | Output | 1 | Output valid |

#### Pipeline Latency
**1 clock cycle** (single registered stage)

#### Resource Estimate
~30–50 LUTs (barrel shifter / mux logic)

---

### 3. DPTC Encoder (Delta Predictive Transform Coding)

**Source:** [`rtl/dptc_encoder.v`](rtl/dptc_encoder.v) — 85 lines  
**Purpose:** Removes temporal redundancy by encoding the difference between consecutive samples instead of absolute values.

#### What It Does

For stable signals (temperature, barometric pressure, magnetometer readings), consecutive samples are nearly identical. Instead of transmitting the full 16-bit value, the DPTC encoder transmits only the **signed delta** and the **minimum number of bits** required to represent it.

#### How It Works Internally

1. **Delta Computation:**
   ```
   diff = sample[n] − prev_sample
   ```
   Implemented as a 17-bit signed subtraction to handle overflow.

2. **Priority Encoder (Bit-Width Calculator):**
   A `calc_width` function determines the minimum number of signed bits needed:

   | Delta Range | Bit Width | Example |
   |---|---|---|
   | `0` | 1 | Zero delta → 1 bit |
   | `−1` to `0` | 2 | Small negative → 2 bits |
   | `−2` to `+1` | 3 | — |
   | `−4` to `+3` | 4 | — |
   | `−8` to `+7` | 5 | — |
   | ... | ... | Cascading ranges |
   | `−8192` to `+8191` | 15 | — |
   | Everything else | 16 | Full width |

3. **Sync Mechanism:** After reset or when `csr_force_reset` is asserted, the `sync_lost` flag is set. The next valid sample is sent as a **full 16-bit absolute value** (with `is_absolute = 1`), and `sync_lost` clears. All subsequent samples are sent as deltas.

#### Interface Signals

| Signal | Direction | Width | Description |
|---|---|---|---|
| `sample_in` | Input | 16 | Quantised input sample |
| `valid_in` | Input | 1 | Input valid |
| `csr_en` | Input | 1 | CSR access enable |
| `csr_force_reset` | Input | 1 | Force re-sync (next sample = absolute) |
| `delta_out` | Output | 16 | Signed delta (or absolute for first sample) |
| `bit_width` | Output | 5 | Significant bits in delta (1–16) |
| `is_absolute` | Output | 1 | `1` = absolute sample, `0` = delta |
| `valid_out` | Output | 1 | Output valid |

#### Compression Examples (Real-World)

| Signal Type | Typical Delta | Bit Width | Compression Ratio |
|---|---|---|---|
| Temperature (slow drift) | `0` or `±1` | 1–2 bits | **8:1 to 16:1** |
| Barometer (smooth) | `±3` to `±7` | 4–5 bits | **3:1 to 4:1** |
| Accelerometer (vibration) | `±50` to `±200` | 8–9 bits | **1.7:1 to 2:1** |
| Impact event (volatile) | `±8000+` | 15–16 bits | **1:1** (no compression) |

#### Pipeline Latency
**1 clock cycle**

#### Resource Estimate
~300–500 LUTs, 0 BRAM

---

### 4. Bit-Packer

**Source:** [`rtl/bit_packer.v`](rtl/bit_packer.v) — 108 lines  
**Purpose:** Packs the variable-width delta stream into dense, byte-aligned output without wasting padding bits.

#### What It Does

Without the Bit-Packer, each 2-bit delta would occupy a full 16-bit word — wasting 87.5% of the bandwidth. The Bit-Packer takes deltas of arbitrary widths (1–16 bits) and stacks them contiguously into a shift register, emitting one byte at a time when 8+ bits have accumulated.

#### How It Works Internally

1. **64-bit Shift Register Accumulator:** A 64-bit register (`accumulator`) holds partially-packed bits. A 7-bit counter (`acc_count`) tracks the number of valid bits currently in the accumulator.

2. **Input Stage:** When `valid_in` is asserted, the incoming delta is masked to `bit_width` bits and OR'd into the accumulator at the current bit position:
   ```
   masked_delta = delta_in & ((1 << bit_width) - 1)
   accumulator <= accumulator | (masked_delta << acc_count)
   acc_count   <= acc_count + bit_width
   ```

3. **Output Stage:** When `acc_count >= 8`, the lowest byte is emitted and the accumulator shifts right by 8:
   ```
   byte_out    <= accumulator[7:0]
   accumulator <= accumulator >> 8
   acc_count   <= acc_count - 8
   ```

4. **Chunk Boundary:** After `N` samples have been packed (default `N = 64`, configurable via `csr_chunk_size`), the `chunk_done` signal is asserted. This triggers the CCSDS Framer to close the current packet. If there are remaining bits that don't fill a complete byte, a partial byte is flushed with zero-padding in the unused MSBs.

5. **CSR Force Flush:** The RV32E or ARM can force an immediate chunk boundary by asserting `csr_force_flush`, which is useful when switching compression modes mid-stream.

#### Interface Signals

| Signal | Direction | Width | Description |
|---|---|---|---|
| `delta_in` | Input | 16 | Delta value from DPTC |
| `bit_width` | Input | 5 | Bit width of this delta (1–16) |
| `is_absolute` | Input | 1 | Absolute sample flag |
| `valid_in` | Input | 1 | Input valid |
| `csr_en` | Input | 1 | CSR access enable |
| `csr_force_flush` | Input | 1 | Force chunk completion |
| `csr_chunk_size` | Input | 16 | Samples per chunk (default 64) |
| `byte_out` | Output | 8 | Packed output byte |
| `byte_valid` | Output | 1 | Output byte is valid |
| `chunk_done` | Output | 1 | Asserted when N samples have been packed |

#### Parameter

| Parameter | Default | Description |
|---|---|---|
| `MAX_CHUNK_SIZE` | `64` | Maximum samples per output chunk |

#### Resource Estimate
~250–400 LUTs, 0 BRAM

---

### 5. CCSDS Framer

**Source:** [`rtl/ccsds_framer.v`](rtl/ccsds_framer.v) — 191 lines  
**Purpose:** Wraps the packed byte stream into **CCSDS Space Packet Protocol** (SPP, Blue Book CCSDS 133.0-B-2) compliant telemetry packets.

#### What It Does

Each time the Bit-Packer signals `chunk_done`, the CCSDS Framer:
1. Buffers the payload in a 256-byte internal RAM (store-and-forward)
2. Emits a 6-byte **CCSDS Primary Header**
3. Emits a 5-byte **Secondary Header** with timestamp and compression metadata
4. Replays the buffered payload bytes
5. Appends a 2-byte **CRC-16/CCITT** checksum
6. Auto-increments a 14-bit sequence counter

#### CCSDS Packet Format

```
┌──────────────────────────────────────────────────────────────────────┐
│                  CCSDS Primary Header (6 bytes)                      │
├────────────┬────────┬──────────────┬─────────────────────────────────┤
│ Version    │ Type   │ Sec Hdr Flag │ APID (11 bits)                  │
│ 000        │ 0 (TM) │ 1            │ Programmable via CSR            │
├────────────┴────────┴──────────────┴─────────────────────────────────┤
│ Seq Flags (2b) = 11 (standalone) │ Sequence Count (14 bits, auto)    │
├──────────────────────────────────┴───────────────────────────────────┤
│ Packet Data Length (16 bits) = payload + sec_header_size - 1         │
├──────────────────────────────────────────────────────────────────────┤
│                  Secondary Header (5 bytes)                          │
├──────────────────────────────────────────────────────────────────────┤
│ Timestamp (32 bits)  │ Mode (2b) │ Q (4b) │ Reserved (2b)            │
├──────────────────────────────────────────────────────────────────────┤
│                  Packed Delta Payload (variable length)              │
├──────────────────────────────────────────────────────────────────────┤
│                  CRC-16/CCITT (2 bytes, polynomial 0x1021)           │
└──────────────────────────────────────────────────────────────────────┘
```

#### FSM States

The framer operates as a 6-state FSM:

| State | Action |
|---|---|
| `S_IDLE` | Buffers incoming payload bytes into internal RAM. Transitions to `S_PRI_HDR` when `chunk_done` is asserted. |
| `S_PRI_HDR` | Emits the 6-byte CCSDS primary header, byte-by-byte. Feeds each byte into the CRC engine. |
| `S_SEC_HDR` | Emits the 5-byte secondary header (timestamp + mode + Q). Feeds each byte into the CRC engine. |
| `S_PAYLOAD` | Reads buffered payload bytes from RAM and emits them. Each byte feeds the CRC engine. |
| `S_CRC1` | Emits the high byte of the CRC-16 checksum. |
| `S_CRC2` | Emits the low byte of the CRC-16 checksum. Asserts `packet_end`. Returns to `S_IDLE`. |

#### CRC-16/CCITT Implementation

The CRC is computed **incrementally** (one byte per clock cycle) using a bit-wise calculation equivalent to a lookup table:
```
Polynomial: 0x1021
Init:       0xFFFF
No input/output bit reversal
No final XOR
```
The `next_crc` function in the RTL implements this as an 8-iteration loop over each input bit, which synthesises into ~32 XOR gates.

#### Interface Signals

| Signal | Direction | Width | Description |
|---|---|---|---|
| `payload_byte` | Input | 8 | Packed byte from Bit-Packer |
| `payload_valid` | Input | 1 | Byte valid from Bit-Packer |
| `chunk_done` | Input | 1 | End-of-chunk signal from Bit-Packer |
| `mode` | Input | 2 | Current compression mode (for secondary header) |
| `q_out` | Input | 4 | Quantisation level (for secondary header) |
| `timestamp` | Input | 32 | Timestamp value (for secondary header) |
| `csr_en` | Input | 1 | CSR enable |
| `csr_apid` | Input | 11 | Application Process Identifier |
| `byte_out` | Output | 8 | CCSDS packet byte |
| `byte_valid` | Output | 1 | Output byte is valid |
| `packet_start` | Output | 1 | First byte of a new packet |
| `packet_end` | Output | 1 | Last byte (final CRC byte) of a packet |

#### Resource Estimate
~100–200 LUTs, 0 BRAM (256-byte buffer inferred as distributed RAM)

---

### 6. ASCON-128a Encryption Core

**Source:** [`rtl/ascon128a_core.v`](rtl/ascon128a_core.v) — 189 lines  
**Purpose:** Provides **Authenticated Encryption with Associated Data (AEAD)** using the 2023 NIST Lightweight Cryptography standard.

#### Why ASCON Instead of AES?

| Metric | AES-128 (iterative) | ASCON-128a |
|---|---|---|
| Area | ~1,600 LUTs | **~350 LUTs** |
| Rounds per block | 10 | 12 (init) + 8 (data) |
| State width | 128 bits | **320 bits** (sponge) |
| Authentication | Separate MAC needed | **Built-in** (AEAD) |
| NIST Standard | FIPS 197 (2001) | **NIST LWC (2023)** |

ASCON provides a **~4× area reduction** over AES while adding built-in authentication — the 128-bit Tag proves the ciphertext hasn't been tampered with.

#### How It Works Internally

ASCON operates on a **320-bit state** split into five 64-bit words (`x0`–`x4`). The core implements a full ASCON permutation round in a single clock cycle using combinational logic:

**Step 1 — Constant Addition:**
```
x2 = x2 ⊕ round_constant[round_cnt]
```

**Step 2 — Substitution Layer (5-bit S-Box):**
Applied bitwise across all 64-bit positions of the five state words simultaneously. This is the non-linear component that provides confusion:
```
x0' = x0 ⊕ x4        (pre-mix)
x4' = x4 ⊕ x3
x2' = x2 ⊕ x1

t0 = ~x0' & x1        (AND-NOT operations)
t1 = ~x1  & x2'
...

Final S-box output: XOR combinations of tᵢ with pre-mixed values
```

**Step 3 — Linear Diffusion Layer:**
Each state word is XOR'd with two rotated copies of itself. The rotation amounts are specific to each word and provide diffusion:
```
x0 = x0 ⊕ (x0 >>> 19) ⊕ (x0 >>> 28)
x1 = x1 ⊕ (x1 >>> 61) ⊕ (x1 >>> 39)
x2 = x2 ⊕ (x2 >>> 1)  ⊕ (x2 >>> 6)
x3 = x3 ⊕ (x3 >>> 10) ⊕ (x3 >>> 17)
x4 = x4 ⊕ (x4 >>> 7)  ⊕ (x4 >>> 41)
```

#### FSM Flow

```
S_IDLE ──► S_INIT_P (12 rounds) ──► S_K_XOR1 ──► S_AD_PAD ──► S_PT_XOR
                                                                    │
S_TAG ◄── S_FINAL_P (12 rounds) ◄── S_FINAL ◄──────────────────────┘
  │
  └──► Output ciphertext[127:0] + tag[127:0], assert ct_valid
```

| Phase | Rounds | Purpose |
|---|---|---|
| Initialisation (`p12`) | 12 | IV ‖ Key ‖ Nonce → Permute → XOR Key |
| AD Domain Separation | 1 cycle | XOR `0x01` into `x4` (empty AD case) |
| Plaintext Absorption | 1 cycle | XOR plaintext into `x0‖x1`, emit ciphertext |
| Finalisation (`p12`) | 12 | Key mix → Permute → Extract Tag |

**Total latency:** ~28 clock cycles per 128-bit block (12 + 1 + 1 + 1 + 12 + 1)

#### Interface Signals

| Signal | Direction | Width | Description |
|---|---|---|---|
| `key` | Input | 128 | Encryption key |
| `nonce` | Input | 128 | Nonce (must be unique per encryption) |
| `plaintext` | Input | 128 | Plaintext input block |
| `pt_valid` | Input | 1 | Start encryption |
| `ciphertext` | Output | 128 | Encrypted output block |
| `tag` | Output | 128 | Authentication tag |
| `ct_valid` | Output | 1 | Encryption complete, outputs valid |
| `busy` | Output | 1 | Core is processing |

#### Verification
The testbench `tb/tb_ascon128a.v` validates the output ciphertext and tag against official **NIST LWC Known Answer Test (KAT)** vectors from `LWC_AEAD_KAT_128_128.txt`.

#### Resource Estimate
~350 LUTs, 0 BRAM, 0 DSP

---

### 7. FIFO Buffer (Rate Matching)

**Source:** [`rtl/fifo_sync.v`](rtl/fifo_sync.v) — 95 lines  
**Purpose:** Absorbs the speed mismatch between the fast FPGA pipeline and the slow UART/SPI transmitter.

#### What It Does

The compression pipeline can burst bytes at the system clock rate (e.g., 100 MHz → 100 MB/s), but a UART at 115200 baud can only consume ~11.5 KB/s. The FIFO acts as a **2048-byte elastic buffer** to absorb these bursts without data loss.

#### How It Works Internally

- **Storage:** A `DEPTH`-element RAM array (default 2048 × 8-bit) that Vivado/Quartus infers as a **Block RAM (BRAM)**.
- **Pointers:** Separate `wr_ptr` and `rd_ptr` with a `count` register tracking fill level.
- **Write:** When `wr_en` is asserted and the FIFO is not full, data is written to `ram[wr_ptr]` and `wr_ptr` increments.
- **Read:** When `rd_en` is asserted and the FIFO is not empty, `rd_data` is loaded from `ram[rd_ptr]` and `rd_ptr` increments.
- **Overflow Protection:** If a write is attempted when full, a sticky `overflow` flag latches high. It can only be cleared by the RV32E/ARM writing to `csr_clear_overflow`.
- **Status Flags:** `full`, `empty`, `almost_full` (level ≥ configurable watermark), `almost_empty` (level ≤ 25%).
- **CSR Flush:** Writing `csr_flush` resets all pointers and count to zero — clearing the entire buffer.

#### Parameters

| Parameter | Default | Description |
|---|---|---|
| `DATA_WIDTH` | `8` | Data word width (bits) |
| `DEPTH_LOG2` | `11` | log₂ of FIFO depth (11 → 2048 entries) |

#### Resource Estimate
~100 LUTs (control logic), 1 BRAM block (18 Kb)

---

## 🧠 RV32E Supervisor Core

The RV32E is a minimal 32-bit RISC-V processor (base integer ISA, 16 registers) that acts as the **intelligent control plane** for the pipeline.

### Core Specification

| Parameter | Value |
|---|---|
| ISA | RV32E (16 registers, 32-bit) |
| Microarchitecture | Multicycle FSM (3–5 CPI) |
| Pipeline stages | None (FSM-based, not pipelined) |
| Clock | Same system clock as the data pipeline |
| Instruction memory | 4 KB BRAM (ROM — firmware burned at synthesis) |
| Data memory | 2 KB BRAM (stack + variables) |
| Extensions | None (base integer only) |
| Interrupts | 8 external IRQ lines |

### What the RV32E Does

The RV32E does **not** participate in the data path. It runs two firmware routines:

#### 1. Initialisation Sequence
At power-up, the firmware configures every pipeline stage:
```c
void init_pipeline(void) {
    ANA_THRESH_LOW  = 50;            // Edge Analytics thresholds
    ANA_THRESH_HIGH = 200;

    AES_KEY_0 = 0x2B7E1516;         // Load encryption key
    AES_KEY_1 = 0x28AED2A6;         // (4 × 32-bit writes)
    AES_KEY_2 = 0xABF71588;
    AES_KEY_3 = 0x09CF4F3C;
    AES_CTRL  = 0x03;                // Enable + key-update trigger

    UART_BAUD_DIV = 867;             // 115200 baud @ 100 MHz
    FIFO_WATERMARK = 1536;           // 75% of 2048 bytes
    ANA_CTRL = 0x01;                 // Enable analytics engine
}
```

#### 2. Runtime Monitoring Loop
Continuously monitors pipeline health and adapts parameters:
```c
void monitor_loop(void) {
    while (1) {
        // If FIFO is filling up, increase compression aggressiveness
        if (FIFO_STATUS & 0x04) {    // almost_full flag
            ANA_THRESH_LOW  = 120;   // Higher threshold -> more stable lossy
            ANA_THRESH_HIGH = 100;
        }

        // Clear sticky overflow flag if set
        if (FIFO_STATUS & 0x08) {
            FIFO_CTRL = 0x04;
        }
    }
}
```

### Memory Map

```
0x0000_0000 ┌─────────────────────────────┐
            │  Instruction ROM (4 KB)     │  Firmware code
0x0000_0FFF ├─────────────────────────────┤
0x0000_1000 │  Data RAM (2 KB)            │  Stack + variables
0x0000_17FF ├─────────────────────────────┤
            │  (Reserved)                 │
0x1000_0000 ├─────────────────────────────┤
            │  Ethernet RX CSRs           │  0x1000_0000 – 0x1000_001F
0x1000_1000 ├─────────────────────────────┤
            │  Edge Analytics CSRs        │  0x1000_1000 – 0x1000_101F
0x1000_2000 ├─────────────────────────────┤
            │  Quantiser CSRs             │  0x1000_2000 – 0x1000_200F
0x1000_3000 ├─────────────────────────────┤
            │  DPTC Encoder CSRs          │  0x1000_3000 – 0x1000_301F
0x1000_4000 ├─────────────────────────────┤
            │  Bit-Packer CSRs            │  0x1000_4000 – 0x1000_400F
0x1000_4800 ├─────────────────────────────┤
            │  CCSDS Framer CSRs          │  0x1000_4800 – 0x1000_480F
0x1000_5000 ├─────────────────────────────┤
            │  ASCON Core CSRs            │  0x1000_5000 – 0x1000_501F
0x1000_6000 ├─────────────────────────────┤
            │  FIFO CSRs                  │  0x1000_6000 – 0x1000_600F
0x1000_7000 ├─────────────────────────────┤
            │  UART TX CSRs               │  0x1000_7000 – 0x1000_700F
            └─────────────────────────────┘
```

### Interrupt Sources

| IRQ | Source | Trigger Condition |
|---|---|---|
| `IRQ[0]` | Ethernet RX | Frame error detected |
| `IRQ[1]` | Edge Analytics | Mode change occurred |
| `IRQ[2]` | DPTC Encoder | Sync lost (gap in valid stream) |
| `IRQ[3]` | CCSDS Framer | Packet completed |
| `IRQ[4]` | ASCON Core | Encryption complete |
| `IRQ[5]` | FIFO | Almost-full threshold crossed |
| `IRQ[6]` | FIFO | Overflow occurred |
| `IRQ[7]` | UART TX | Transmission idle |

---

## 🦾 ARM Controller Interaction

This section describes how an **ARM host processor** (e.g., ARM Cortex-A9 in Xilinx Zynq-7020, or ARM Cortex-A9 in NI sbRIO-9627) interacts with the TCC core. This is the primary integration model for SoC deployments.

### Architecture: Dual-Master Model

When the TCC is embedded inside a Zynq or similar ARM+FPGA SoC, both the internal RV32E and the external ARM processor can access the pipeline's CSR registers. A **priority arbiter** guards the CSR bus:

```
┌──────────────────────┐                    ┌──────────────────────┐
│  ARM Cortex-A9       │                    │  RV32E Supervisor    │
│  (Processing System) │                    │  (Programmable Logic)│
│                      │                    │                      │
│  Linux / FreeRTOS    │                    │  Bare-metal firmware │
│  AXI-Lite Master     │                    │  Internal CSR access │
└──────────┬───────────┘                    └──────────┬───────────┘
           │                                           │
           ▼                                           ▼
     ┌───────────────────────────────────────────────────────┐
     │                  Priority Arbiter                     │
     │                                                       │
     │  ARM has priority (HOST_OVERRIDE bit per module)      │
     │  When HOST_OVERRIDE = 1 for a module, the RV32E's     │
     │  writes to that module's CSRs are blocked.            │
     └───────────────────────┬───────────────────────────────┘
                             │
                      CSR Register File
                      (all 7 pipeline modules)
```

### How the ARM Sends Data to the TCC

#### Method 1: AXI-Stream via DMA (High Throughput)

The ARM reads sensor data from its own peripherals (SPI, I2C, ADC) and writes samples into a memory buffer. A DMA controller then blasts the buffer into the TCC's AXI-Stream input port at bus speed.

```
ARM reads sensors          DMA Controller          TCC Pipeline
      │                         │                       │
      │── write samples ──►     │                       │
      │   to DDR buffer         │                       │
      │                         │                       │
      │── trigger DMA ────►     │                       │
      │                         │── s_axis_tdata ──►    │
      │                         │── s_axis_tvalid ──►   │
      │                         │◄── s_axis_tready ──   │
      │                         │                       │── process ──►
```

**AXI-Stream Input Port Signals:**

| Signal | Direction | Width | Description |
|---|---|---|---|
| `s_axis_tdata` | Input | 16 (configurable) | Sample data |
| `s_axis_tvalid` | Input | 1 | Data is valid |
| `s_axis_tready` | Output | 1 | TCC can accept data (backpressure) |
| `s_axis_tlast` | Input | 1 | Last sample in a burst/frame |
| `s_axis_tuser` | Input | 8 | Sideband: `[3:0]` channel ID, `[7:4]` reserved |
| `s_axis_tid` | Input | 4 | Stream ID (maps to APID in packetiser) |

#### Method 2: CSR-Based Sample Injection (Low Rate, Simple)

For slow sensor data (< 1 kHz), the ARM can bypass DMA entirely and write samples directly into CSRs:

```c
// ARM firmware (C, running on Cortex-A9)
void push_sample(uint16_t sample, uint8_t channel) {
    PIPELINE_SAMPLE_DATA = sample;
    PIPELINE_SAMPLE_TAG  = channel;
    PIPELINE_SAMPLE_PUSH = 1;   // Triggers internal s_axis_tvalid
}
```

### How the ARM Reads TCC Output

The encrypted CCSDS packets exit the TCC on the **AXI-Stream output port**. A second DMA controller captures these packets into DDR memory, where the ARM can forward them to a radio peripheral, Ethernet socket, or filesystem.

**AXI-Stream Output Port Signals:**

| Signal | Direction | Width | Description |
|---|---|---|---|
| `m_axis_tdata` | Output | 8 | Packed/encrypted output byte |
| `m_axis_tvalid` | Output | 1 | Output is valid |
| `m_axis_tready` | Input | 1 | Downstream (radio/DMA) can accept |
| `m_axis_tlast` | Output | 1 | Last byte of a packet |
| `m_axis_tuser` | Output | 2 | `[0]` packet_start, `[1]` encryption_error |

### How the ARM Configures the TCC

The ARM accesses the TCC's CSR registers via an **AXI-Lite slave** interface. Every register that the RV32E can access is also accessible from the ARM side.

**Common ARM Configuration Tasks:**

| Task | ARM Action | CSR Register |
|---|---|---|
| Change compression thresholds | Write new values to Analytics CSRs | `ANA_THRESH_LOW`, `ANA_THRESH_HIGH` |
| Rotate encryption key | Write 4 × 32-bit key words + trigger | `AES_KEY_0` – `AES_KEY_3`, `AES_CTRL` |
| Change UART baud rate | Write new divisor | `UART_BAUD_DIV` |
| Lock out RV32E from a module | Set HOST_OVERRIDE bit | Per-module `_CTRL` register |
| Read pipeline health | Poll status registers | `FIFO_LEVEL`, `ANA_STATUS`, etc. |
| Force compression mode | Set override flag + mode | `ANA_CTRL` |
| Read packet counter | Read CCSDS status | `CCSDS_PKT_COUNT` |

### How the ARM Handles Interrupts

The TCC exports 8 interrupt lines (`irq_vec[7:0]`) and a consolidated OR (`irq_out`). These connect to the ARM's GIC (Generic Interrupt Controller) or the RISC-V PLIC:

```c
// ARM ISR example (FreeRTOS on Zynq)
void tcc_irq_handler(void) {
    uint8_t irq_vec = TCC_IRQ_VEC;

    if (irq_vec & (1 << 5)) {  // FIFO almost full
        // Increase compression aggressiveness
        TCC_ANA_THRESH_LOW  = 20;
        TCC_ANA_THRESH_HIGH = 80;
    }

    if (irq_vec & (1 << 6)) {  // FIFO overflow!
        log_error("TCC FIFO overflow");
        TCC_FIFO_CTRL = 0x04;  // Clear overflow flag
    }

    if (irq_vec & (1 << 1)) {  // Mode change
        uint8_t new_mode = TCC_ANA_STATUS & 0x03;
        log_info("Compression mode changed to %d", new_mode);
    }
}
```



## 🔌 SoC IP Integration Architecture

The TCC is designed as a **self-contained, licensable IP core** with three standard interfaces:

### Complete IP Block Diagram

```
                          AXI-Lite (Control from ARM/RISC-V host)
                               │
   ┌───────────────────────────┼───────────────────────────┐
   │                           │         TCC IP Core       │
   │                     ┌─────▼─────┐                     │
   │                     │  AXI-Lite │                     │
   │                     │  CSR      │                     │
   │                     │  Bridge   │                     │
   │                     └─────┬─────┘                     │
   │                           │                           │
   │          ┌────────────────┼────────────────┐          │
   │          │           RV32E Core            │          │
   │          │    (supervisor + sensor mgmt)   │          │
   │          │     ┌────┐ ┌────┐ ┌────┐       │           │
   │          │     │SPI0│ │SPI1│ │I2C │       │           │
   │          │     └──┬─┘ └──┬─┘ └──┬─┘       │           │
   │          └────────┼──────┼──────┼─────────┘           │
   │                   │      │      │   → Sensor pins     │
   │  ═══════════════════════════════════════════          │
   │                                                       │
   │  AXI-S In ──► ┌───────┐ ┌──────┐ ┌───────┐            │
   │  (samples)    │ Edge  │→│Quant.│→│ DPTC  │            │
   │               │Analyt.│ │      │ │Encoder│            │
   │               └───────┘ └──────┘ └───┬───┘            │
   │                                      │                │
   │               ┌───────┐ ┌──────┐ ┌───▼───┐            │
   │               │ CCSDS │←│ASCON │←│ Bit   │            │
   │               │Framer │ │ AEAD │ │Packer │            │
   │               └───┬───┘ └──────┘ └───────┘            │
   │                   │                                   │
   │                   ▼                                   │
   │               ┌───────┐ ┌──────┐                      │
   │               │ FIFO  │→│Output│──► AXI-S Out         │
   │               │       │ │ MUX  │   (to radio/DMA)     │
   │               └───────┘ └──────┘                      │
   │                                                       │
   │  irq_out[7:0] ◄──── IRQ Controller                    │
   └───────────────────────────────────────────────────────┘
          │            │              │
        Sensor       System         IRQ to
        Pins         Clock          SoC PLIC/GIC
   (SPI/I2C/UART)   + Reset
```

### Sensor Aggregation Tiers

| Tier | Input Method | Cost | Use Case |
|---|---|---|---|
| **Tier 1** | AXI-Stream (SoC DMA pushes samples) | 0 LUTs | TCC inside a larger SoC |
| **Tier 2** | RV32E reads SPI/I2C sensors directly | ~850 LUTs | Standalone TCC on its own PCB |
| **Tier 3** | EtherCAT via external LAN9252 ESC chip | ~0 LUTs (external chip) | Industrial sensor networks |

---

## 📉 Data Width Evolution Through the Pipeline

| Stage | Data Representation | Typical Width |
|---|---|---|
| Raw Input | Unsigned integer samples | 12–16 bits |
| After Quantiser | Right-shifted (reduced precision) | 8–16 bits (depends on Q) |
| After DPTC | Signed deltas between consecutive samples | 2–8 bits typical |
| After Bit-Packer | Dense packed bitstream, byte-aligned | 8 bits per beat |
| After CCSDS Framer | Framed CCSDS Space Packets | 8 bits per beat (+ headers + CRC) |
| After ASCON | 128-bit encrypted cipher blocks | 128 bits → serialised to 8-bit |
| UART Output | Serial byte stream | 1 bit (serial line) |

---

## 📊 FPGA Resource Utilisation

### Per-Module Breakdown

| Module | Estimated LUTs | BRAM | DSP Slices |
|:---|:---|:---|:---|
| Edge Analytics Engine | ~500 | 0 | 0 |
| Quantiser | ~40 | 0 | 0 |
| DPTC Encoder | ~400 | 0 | 0 |
| Bit-Packer | ~350 | 0 | 0 |
| CCSDS Framer | ~150 | 0 | 0 |
| ASCON-128a Core | ~350 | 0 | 0 |
| FIFO Buffer | ~100 | 1 | 0 |
| **Pipeline Subtotal** | **~1,890** | **1** | **0** |
| RV32E Core | ~1,200 | 0 | 0 |
| Instruction ROM (4 KB) | 0 | 1 | 0 |
| Data RAM (2 KB) | 0 | 1 | 0 |
| Bus Interconnect + CSR Decoders | ~300 | 0 | 0 |
| Control / Glue Logic | ~300 | 0 | 0 |
| **Full System Total** | **~3,690** | **3** | **0** |



---

## 📂 Repository Structure

```
TCC/
├── rtl/                          # Synthesisable Verilog-2001 source files
│   ├── edge_analytics.v          # Sliding window MAD & Q-select logic (119 lines)
│   ├── quantiser.v               # Configurable arithmetic shift (42 lines)
│   ├── dptc_encoder.v            # Delta calculator & priority encoder (85 lines)
│   ├── bit_packer.v              # 64-bit barrel shifter & accumulator (108 lines)
│   ├── ccsds_framer.v            # FSM for packet headers & CRC-16 (191 lines)
│   ├── ascon128a_core.v          # ASCON permutation & AEAD state machine (189 lines)
│   └── fifo_sync.v               # BRAM-inferred circular queue (95 lines)
│
├── tb/                           # Verification Testbenches
│   ├── tb_edge_analytics.v       # Validates MAD calculation and mode switching
│   ├── tb_quantiser.v            # Validates arithmetic right-shift for all Q values
│   ├── tb_dptc_encoder.v         # Validates delta computation and bit-width encoding
│   ├── tb_bit_packer.v           # Validates variable-width packing and chunk boundaries
│   ├── tb_ccsds_framer.v         # Validates packet structure and CRC-16
│   ├── tb_ascon128a.v            # Validates against NIST LWC Known Answer Test vectors
│   └── tb_fifo.v                 # Validates FIFO read/write, overflow, and watermarks
│
├── sim/                          # Compiled simulation binaries & waveform files
│   ├── tb_ascon                  # Compiled ASCON testbench binary
│   ├── tb_bitpacker              # Compiled Bit-Packer testbench binary
│   ├── tb_ccsds                  # Compiled CCSDS Framer testbench binary
│   ├── tb_dptc                   # Compiled DPTC testbench binary
│   ├── tb_edge_analytics         # Compiled Edge Analytics testbench binary
│   ├── tb_fifo                   # Compiled FIFO testbench binary
│   ├── tb_quantiser              # Compiled Quantiser testbench binary
│   └── edge_analytics.vcd        # GTKWave waveform dump
│
├── data_flow.md                  # Complete data flow and module specification document
├── soc_ip_architecture.md        # SoC integration architecture (AXI-Stream, AXI-Lite)
├── comparison.md                 # Competitive analysis vs CCSDS Rice, POCKET+, etc.
├── sensor_types.md               # Supported sensor data types and compression performance
├── axi_stream_guide.md           # AXI-Stream interfacing guide with Verilog examples
├── market_analysis.md            # Market sizing, competitive landscape, go-to-market
└── README.md                     # This file
```

---

## 🛠️ Simulation & Verification

The project uses the **Icarus Verilog** (`iverilog`) open-source toolchain. Every module has a corresponding unit test.

### Running a Simulation

```bash
# 1. Compile the RTL + Testbench into a simulation binary
iverilog -o sim/tb_ccsds rtl/ccsds_framer.v tb/tb_ccsds_framer.v

# 2. Execute the compiled simulation
vvp sim/tb_ccsds

# 3. (Optional) View waveforms
gtkwave sim/edge_analytics.vcd
```

### Test Status

| Module | Testbench | Status | Notes |
|:---|:---|:---|:---|
| Edge Analytics | `tb_edge_analytics.v` |  Pass | Validates MAD computation and mode transitions |
| Quantiser | `tb_quantiser.v` |  Pass | Tests all Q-shift values (0–15) |
| DPTC Encoder | `tb_dptc_encoder.v` | Pass | Tests deltas, absolute encoding, sync reset |
| Bit-Packer | `tb_bit_packer.v` |  Pass | Tests variable widths, chunk boundaries, flush |
| CCSDS Framer | `tb_ccsds_framer.v` |  Pass | Validates header fields, payload, CRC-16 |
| ASCON-128a | `tb_ascon128a.v` |  Pass | **Validated against NIST LWC KAT vectors** |
| FIFO | `tb_fifo.v` |  Pass | Tests read/write, overflow, watermarks |

All 7 core modules pass their respective unit tests.

---



## 📝 License & Authorship

Developed for educational and demonstration purposes. Relies on the public domain NIST LWC ASCON standard and CCSDS Blue Book specifications.
