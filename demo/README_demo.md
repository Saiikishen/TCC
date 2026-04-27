# Interactive FPGA Telemetry Demo

This demo turns the TCC project into a live oil-rig telemetry control room:

1. MATLAB generates pressure, flow, and vibration sensor streams.
2. A selected sensor stream is injected into the Verilog `tcc_top` simulation.
3. The FPGA pipeline adapts compression mode, quantisation, DPTC width, packet framing, and FIFO output.
4. The MATLAB-driven testbench applies channel-calibrated MAD thresholds: pressure, flow, and vibration do not share the same stability limit.
5. MATLAB reads the RTL output logs and shows gauges, plots, packet hex, CRC status, and compression ratio.

## Main Audience Demo

From MATLAB, run:

```matlab
cd('\\wsl.localhost\Ubuntu\home\saiikishen\TCC')
addpath('matlab')
run_interactive_demo
```

Use the dashboard controls:

- `Inject Leak`: creates a sharp pressure drop, flow rise, and vibration shock.
- `Run FPGA Simulation`: compiles and runs the real RTL through Icarus Verilog.
- `Start Continuous`: repeatedly generates short sensor windows, runs RTL, and refreshes the dashboard.
- `Show Packet Hex`: shows decoded CCSDS packet headers, mode, Q shift, payload size, and CRC status.
- `Open Waveform`: opens the generated VCD in GTKWave.

## Files Added For The Demo

| File | Purpose |
|---|---|
| `matlab/generate_oilrig_stimulus.m` | Builds realistic oil-rig pressure, flow, and vibration data and writes RTL stimulus. |
| `matlab/run_interactive_demo.m` | Main dashboard with leak injection, live plots, packet stream, and metrics. |
| `matlab/decode_tcc_packets.m` | Decodes CCSDS-style packet bytes emitted by the RTL simulation. |
| `tb/tb_tcc_matlab_driven.v` | MATLAB-driven Verilog testbench for `tcc_top`. |
| `demo/README_demo.md` | This runbook and presentation guide. |

Generated files land in:

```text
demo/generated/
```

Important generated outputs:

| File | Meaning |
|---|---|
| `oilrig_timeseries.csv` | Full pressure, flow, vibration scenario. |
| `oilrig_pressure.mem` | RTL stimulus for the selected FPGA input channel. |
| `fpga_trace.csv` | Cycle-level pipeline trace for MATLAB visualization. |
| `fpga_packets.csv` | Byte-level output packet stream. |
| `packet_decode.txt` | Human-readable packet decode. |
| `tb_tcc_matlab_driven.vcd` | GTKWave waveform file. |

## Headless RTL Run

If you want to prove the simulation path without opening the dashboard:

```matlab
cd('\\wsl.localhost\Ubuntu\home\saiikishen\TCC')
addpath('matlab')
[~, p] = generate_oilrig_stimulus('Channel', 'pressure', 'SampleCount', 4096, 'LeakSeverity', 1.4);
```

Then from WSL:

```bash
cd /home/saiikishen/TCC
iverilog -g2012 -o sim/tb_tcc_matlab_driven rtl/*.v tb/tb_tcc_matlab_driven.v
vvp sim/tb_tcc_matlab_driven \
  +STIM=demo/generated/oilrig_pressure.mem \
  +TRACE=demo/generated/fpga_trace.csv \
  +PACKETS=demo/generated/fpga_packets.csv \
  +SUMMARY=demo/generated/fpga_summary.txt \
  +VCD=demo/generated/tb_tcc_matlab_driven.vcd
```

Back in MATLAB:

```matlab
packets = decode_tcc_packets('demo/generated/fpga_packets.csv', ...
    'OutFile', 'demo/generated/packet_decode.txt');
```

## Presentation Flow

### 1. Start Calm

Show normal oil-rig telemetry:

- Pressure near 1500 PSI.
- Flow near 500 GPM.
- Vibration around the motor harmonic.
- FPGA mode mostly stable lossy to save bandwidth.
- Small quantised deltas after DPTC.

Say: "This is not a MATLAB-only animation. MATLAB is feeding a Verilog RTL simulation."

### 2. Make The Audience Touch It

Ask someone to press `Inject Leak`.

The expected visual moment:

- Pressure collapses.
- Flow rises.
- Vibration shock appears.
- The leak is a sharp transient and recovers back to normal in roughly 1-2 seconds.
- FPGA mode/Q/MAD indicators react and switch to lossless detail preservation during the transient.
- Packet stream continues without FIFO overflow.

### 3. Show Compression

Press `Run FPGA Simulation`.

Point to:

- Raw sensor bytes.
- TCC output bytes.
- Compression ratio.
- Packet count.
- CRC pass.
- FIFO health.

### 4. Show Real Packets

Press `Show Packet Hex`.

Call out:

- APID.
- Sequence count.
- Mode.
- Q shift.
- Payload length.
- CRC pass.

This makes the system feel like a real telemetry link rather than a chart demo.

### 5. Show The Hardware Proof

Press `Open Waveform`.

In GTKWave, add or inspect:

- `s_axis_tdata`
- `s_axis_tvalid`
- `s_axis_tready`
- `status_mode`
- `uut.ana_q_out`
- `uut.u_edge.current_mad`
- `m_axis_tdata`
- `m_axis_tvalid`
- `m_axis_tlast`
- `status_overflow`

This is the credibility anchor: the dashboard is driven by actual RTL outputs.

## Wow Factor Checklist

- Big `Inject Leak` button.
- Live raw sensor plot.
- Adaptive mode and MAD plot.
- Raw-vs-output bandwidth chart.
- Compression ratio meter.
- Packet counter.
- FIFO health indicator.
- CRC pass indicator.
- Scrolling packet hex console.
- One-click GTKWave launch.
- Audience-selectable FPGA input channel.

## Technical Note

The current `tcc_top.v` top-level keeps the ASCON stage as a passthrough for integration bring-up. The standalone ASCON module and testbench remain in the project, but the live top-level demo currently proves the full path through adaptive analytics, quantisation, DPTC, bit packing, CCSDS framing, FIFO buffering, AXI-stream output, packet decode, and waveform inspection.

## Channel Thresholds

The live MATLAB-driven simulation uses different MAD thresholds per sensor channel:

| Channel | Stable lossy if MAD < | Detail preserve if MAD >= | Why |
|---|---:|---:|---|
| Pressure | 320 | 320 | Healthy pump ripple is normal and should still compress. |
| Flow | 60 | 60 | Healthy flow is much steadier, so small changes matter sooner. |
| Vibration | 900 | 900 | Healthy motor harmonics are large in ADC counts. |

The high threshold is also passed into the RTL for anomaly classification headroom:

| Channel | High MAD threshold |
|---|---:|
| Pressure | 900 |
| Flow | 450 |
| Vibration | 2400 |
