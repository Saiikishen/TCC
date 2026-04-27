function run_interactive_demo
%RUN_INTERACTIVE_DEMO Launch the interactive MATLAB control-room demo.
%
% This dashboard generates oil-rig sensor data, runs the Verilog TCC
% simulation through Icarus Verilog, and visualizes packets, modes, FIFO
% health, and compression ratio.

repoRoot = fileparts(fileparts(mfilename('fullpath')));
addpath(fullfile(repoRoot, 'matlab'));

state = struct();
state.repoRoot = repoRoot;
state.stimulus = table();
state.paths = struct();
state.trace = table();
state.packets = table();
state.continuous = false;
state.isBusy = false;
state.streamStartSec = 0;
state.runIndex = 0;
state.leakEventTimeSec = Inf;
state.demoTimer = [];
state.simBuilt = false;

fig = uifigure('Name', 'Oil Rig FPGA Telemetry Demo', ...
    'Position', [80 80 1420 820], ...
    'Color', [0.07 0.08 0.10]);
fig.CloseRequestFcn = @(~,~) closeDemo();

main = uigridlayout(fig, [3 4]);
main.RowHeight = {230, '1x', 190};
main.ColumnWidth = {290, '1x', '1x', 380};
main.Padding = [12 12 12 12];
main.RowSpacing = 10;
main.ColumnSpacing = 10;

controlPanel = uipanel(main, 'Title', 'Live Controls', ...
    'BackgroundColor', [0.11 0.12 0.15], ...
    'ForegroundColor', [0.92 0.94 0.96]);
controlPanel.Layout.Row = [1 3];
controlPanel.Layout.Column = 1;

controls = uigridlayout(controlPanel, [16 2]);
controls.RowHeight = {28, 28, 28, 42, 28, 42, 28, 42, 28, 42, 34, 34, 34, 34, '1x', 34};
controls.ColumnWidth = {'1x', '1x'};
controls.Padding = [10 8 10 10];
controls.RowSpacing = 7;

channelLabel = uilabel(controls, 'Text', 'FPGA input channel', 'FontColor', [0.86 0.88 0.91]);
channelLabel.Layout.Row = 1;
channelLabel.Layout.Column = 1;
channelDrop = uidropdown(controls, ...
    'Items', {'pressure', 'flow', 'vibration', 'interleaved'}, ...
    'Value', 'pressure', ...
    'ValueChangedFcn', @(~,~) refreshScenario());
channelDrop.Layout.Row = 1;
channelDrop.Layout.Column = 2;

sampleLabelCtl = uilabel(controls, 'Text', 'Samples', 'FontColor', [0.86 0.88 0.91]);
sampleLabelCtl.Layout.Row = 2;
sampleLabelCtl.Layout.Column = 1;
sampleDrop = uidropdown(controls, ...
    'Items', {'1024', '2048', '4096', '8192'}, ...
    'Value', '4096', ...
    'ValueChangedFcn', @(~,~) refreshScenario());
sampleDrop.Layout.Row = 2;
sampleDrop.Layout.Column = 2;

leakStartLabel = uilabel(controls, 'Text', 'Leak start (s)', 'FontColor', [0.86 0.88 0.91]);
leakStartLabel.Layout.Row = 3;
leakStartLabel.Layout.Column = [1 2];
leakStart = uislider(controls, 'Limits', [0.25 6.5], 'Value', 2.4, ...
    'MajorTicks', [0.5 2.5 4.5 6.5], ...
    'ValueChangedFcn', @(~,~) refreshScenario());
leakStart.Layout.Row = 4;
leakStart.Layout.Column = [1 2];

leakSeverityLabel = uilabel(controls, 'Text', 'Leak severity', 'FontColor', [0.86 0.88 0.91]);
leakSeverityLabel.Layout.Row = 5;
leakSeverityLabel.Layout.Column = [1 2];
leakSeverity = uislider(controls, 'Limits', [0 1.8], 'Value', 1.0, ...
    'MajorTicks', [0 0.6 1.2 1.8], ...
    'ValueChangedFcn', @(~,~) refreshScenario());
leakSeverity.Layout.Row = 6;
leakSeverity.Layout.Column = [1 2];

noiseLabel = uilabel(controls, 'Text', 'Noise level', 'FontColor', [0.86 0.88 0.91]);
noiseLabel.Layout.Row = 7;
noiseLabel.Layout.Column = [1 2];
noiseLevel = uislider(controls, 'Limits', [0 3.0], 'Value', 1.0, ...
    'MajorTicks', [0 1 2 3], ...
    'ValueChangedFcn', @(~,~) refreshScenario());
noiseLevel.Layout.Row = 8;
noiseLevel.Layout.Column = [1 2];

injectButton = uibutton(controls, 'push', 'Text', 'Inject Leak', ...
    'FontWeight', 'bold', ...
    'BackgroundColor', [0.78 0.20 0.18], ...
    'FontColor', [1 1 1], ...
    'ButtonPushedFcn', @(~,~) injectLeak());
injectButton.Layout.Row = 9;
injectButton.Layout.Column = [1 2];

runButton = uibutton(controls, 'push', 'Text', 'Run FPGA Simulation', ...
    'FontWeight', 'bold', ...
    'BackgroundColor', [0.10 0.42 0.64], ...
    'FontColor', [1 1 1], ...
    'ButtonPushedFcn', @(~,~) runSimulation());
runButton.Layout.Row = 10;
runButton.Layout.Column = [1 2];

continuousButton = uibutton(controls, 'push', 'Text', 'Start Continuous', ...
    'FontWeight', 'bold', ...
    'BackgroundColor', [0.12 0.48 0.27], ...
    'FontColor', [1 1 1], ...
    'ButtonPushedFcn', @(~,~) toggleContinuous());
continuousButton.Layout.Row = 11;
continuousButton.Layout.Column = [1 2];

packetButton = uibutton(controls, 'push', 'Text', 'Show Packet Hex', ...
    'ButtonPushedFcn', @(~,~) showPacketHex());
packetButton.Layout.Row = 12;
packetButton.Layout.Column = [1 2];

waveButton = uibutton(controls, 'push', 'Text', 'Open Waveform', ...
    'ButtonPushedFcn', @(~,~) openWaveform());
waveButton.Layout.Row = 13;
waveButton.Layout.Column = [1 2];

metricPanel = uipanel(controls, 'Title', 'Mission Metrics', ...
    'BackgroundColor', [0.09 0.10 0.13], ...
    'ForegroundColor', [0.92 0.94 0.96]);
metricPanel.Layout.Column = [1 2];
metricPanel.Layout.Row = [14 16];

metrics = uigridlayout(metricPanel, [4 2]);
metrics.Padding = [8 6 8 6];
metrics.RowHeight = {'1x', '1x', '1x', '1x'};
metrics.ColumnWidth = {'1x', '1x'};

modeLabel = metricLabel(metrics, 'MODE: pending');
qLabel = metricLabel(metrics, 'Q: pending');
ratioLabel = metricLabel(metrics, 'RATIO: pending');
packetLabel = metricLabel(metrics, 'PACKETS: pending');
crcLabel = metricLabel(metrics, 'CRC: pending');
fifoLabel = metricLabel(metrics, 'FIFO: pending');
latencyLabel = metricLabel(metrics, 'LATENCY: pending');
sampleLabel = metricLabel(metrics, 'SAMPLES: pending');

sensorAx = uiaxes(main);
sensorAx.Layout.Row = 1;
sensorAx.Layout.Column = [2 3];
title(sensorAx, 'Oil Rig Digital Twin');
xlabel(sensorAx, 'Time (s)');
ylabel(sensorAx, 'Engineering units');
grid(sensorAx, 'on');

pipelineAx = uiaxes(main);
pipelineAx.Layout.Row = 2;
pipelineAx.Layout.Column = 2;
title(pipelineAx, 'FPGA Adaptive Mode');
xlabel(pipelineAx, 'Simulation cycle');
grid(pipelineAx, 'on');

bandwidthAx = uiaxes(main);
bandwidthAx.Layout.Row = 2;
bandwidthAx.Layout.Column = 3;
title(bandwidthAx, 'Raw vs Packetized Bandwidth');
ylabel(bandwidthAx, 'Bytes');
grid(bandwidthAx, 'on');

packetConsole = uitextarea(main, ...
    'FontName', 'Consolas', ...
    'FontSize', 12, ...
    'Value', {'Packet stream will appear here after simulation.'});
packetConsole.Layout.Row = [1 3];
packetConsole.Layout.Column = 4;

lampPanel = uipanel(main, 'Title', 'Pipeline Activity', ...
    'BackgroundColor', [0.09 0.10 0.13], ...
    'ForegroundColor', [0.92 0.94 0.96]);
lampPanel.Layout.Row = 3;
lampPanel.Layout.Column = [2 3];

lampGrid = uigridlayout(lampPanel, [2 6]);
lampGrid.Padding = [10 8 10 8];
lampGrid.ColumnWidth = repmat({'1x'}, 1, 6);
lampGrid.RowHeight = {'1x', 24};
lampNames = {'EDGE', 'QUANT', 'DPTC', 'PACK', 'CCSDS', 'FIFO'};
lamps = gobjects(1, 6);
for k = 1:6
    lamps(k) = uilabel(lampGrid, 'Text', lampNames{k}, ...
        'HorizontalAlignment', 'center', ...
        'FontWeight', 'bold', ...
        'BackgroundColor', [0.21 0.23 0.27], ...
        'FontColor', [0.88 0.90 0.94]);
    lamps(k).Layout.Row = 1;
    lamps(k).Layout.Column = k;
    caption = uilabel(lampGrid, 'Text', stageCaption(k), ...
        'HorizontalAlignment', 'center', ...
        'FontSize', 10, ...
        'FontColor', [0.72 0.76 0.80]);
    caption.Layout.Row = 2;
    caption.Layout.Column = k;
end

state.demoTimer = timer( ...
    'ExecutionMode', 'fixedSpacing', ...
    'Period', 0.25, ...
    'BusyMode', 'drop', ...
    'TimerFcn', @(~,~) continuousTick());

refreshScenario();

    function refreshScenario()
        if state.continuous
            stopContinuous();
        end
        sampleCount = str2double(sampleDrop.Value);
        [state.stimulus, state.paths] = generate_oilrig_stimulus( ...
            'OutputDir', fullfile(repoRoot, 'demo', 'generated'), ...
            'Channel', channelDrop.Value, ...
            'SampleCount', sampleCount, ...
            'LeakStartSec', leakStart.Value, ...
            'LeakSeverity', leakSeverity.Value, ...
            'NoiseLevel', noiseLevel.Value, ...
            'TimeOffsetSec', 0, ...
            'Quiet', true);
        state.streamStartSec = 0;
        state.leakEventTimeSec = Inf;
        plotScenario();
        setPendingMetrics();
        packetConsole.Value = { ...
            sprintf('Scenario ready: %s channel', channelDrop.Value), ...
            sprintf('Stimulus: %s', state.paths.memFile), ...
            'Press Run FPGA Simulation once, or Start Continuous for live windows.'};
        setLamps([0 0 0 0 0 0]);
    end

    function injectLeak()
        leakSeverity.Value = 1.6;
        if state.continuous
            state.leakEventTimeSec = state.streamStartSec + 0.12;
            packetConsole.Value = { ...
                sprintf('Leak injected at t=%.3f s.', state.leakEventTimeSec), ...
                'Next live FPGA window will show a sharp transient and recovery.'};
        else
            leakStart.Value = max(0.25, min(1.0, 0.18 * str2double(sampleDrop.Value) / 1000));
            refreshScenario();
        end
    end

    function runSimulation()
        if state.continuous
            stopContinuous();
        end
        runButton.Text = 'Running RTL...';
        runButton.Enable = 'off';
        drawnow;
        try
            runCurrentWindow();
        catch ME
            packetConsole.Value = splitlines(string(getReport(ME, 'extended', 'hyperlinks', 'off')));
            setLamps([0 0 0 0 0 0]);
        end
        runButton.Text = 'Run FPGA Simulation';
        runButton.Enable = 'on';
    end

    function toggleContinuous()
        if state.continuous
            stopContinuous();
        else
            state.continuous = true;
            state.streamStartSec = 0;
            state.runIndex = 0;
            state.leakEventTimeSec = Inf;
            continuousButton.Text = 'Stop Continuous';
            continuousButton.BackgroundColor = [0.70 0.18 0.16];
            runButton.Enable = 'off';
            packetConsole.Value = { ...
                'Continuous mode running.', ...
                'Each update generates a fresh sensor window, runs RTL, and refreshes packets.'};
            start(state.demoTimer);
            continuousTick();
        end
    end

    function stopContinuous()
        state.continuous = false;
        if ~isempty(state.demoTimer) && isvalid(state.demoTimer)
            stop(state.demoTimer);
        end
        continuousButton.Text = 'Start Continuous';
        continuousButton.BackgroundColor = [0.12 0.48 0.27];
        runButton.Enable = 'on';
    end

    function continuousTick()
        if ~state.continuous || state.isBusy || ~isvalid(fig)
            return;
        end

        state.isBusy = true;
        continuousButton.Text = 'Running Window...';
        drawnow;
        try
            sampleCount = str2double(sampleDrop.Value);
            windowStart = state.streamStartSec;
            [state.stimulus, state.paths] = generate_oilrig_stimulus( ...
                'OutputDir', fullfile(repoRoot, 'demo', 'generated'), ...
                'Channel', channelDrop.Value, ...
                'SampleCount', sampleCount, ...
                'LeakStartSec', state.leakEventTimeSec, ...
                'LeakSeverity', leakSeverity.Value, ...
                'NoiseLevel', noiseLevel.Value, ...
                'TimeOffsetSec', windowStart, ...
                'Seed', 23 + state.runIndex, ...
                'Quiet', true);
            plotScenario();
            runCurrentWindow();
            state.streamStartSec = windowStart + height(state.stimulus) / 1000;
            state.runIndex = state.runIndex + 1;
            if state.streamStartSec > state.leakEventTimeSec + 2.2
                state.leakEventTimeSec = Inf;
            end
        catch ME
            packetConsole.Value = splitlines(string(getReport(ME, 'extended', 'hyperlinks', 'off')));
            setLamps([0 0 0 0 0 0]);
            stopContinuous();
        end
        state.isBusy = false;
        if state.continuous
            continuousButton.Text = 'Stop Continuous';
        end
    end

    function runCurrentWindow()
        [ok, msg] = runIcarus(repoRoot, state.paths, ~state.simBuilt);
        if ~ok
            packetConsole.Value = splitlines(string(msg));
            setLamps([0 0 0 0 0 0]);
            return;
        end
        state.simBuilt = true;
        state.trace = readtable(state.paths.traceCsv);
        state.packets = decode_tcc_packets(state.paths.packetCsv, ...
            'OutFile', state.paths.decodeTxt, 'Quiet', true);
        updateFpgaPlots();
        updateMetrics();
        showPacketHex();
        setLamps([1 1 1 1 1 1]);
    end

    function plotScenario()
        cla(sensorAx);
        t = state.stimulus.time_s;
        channel = lower(channelDrop.Value);
        yyaxis(sensorAx, 'right');
        cla(sensorAx);
        yyaxis(sensorAx, 'left');
        cla(sensorAx);
        hold(sensorAx, 'on');
        switch channel
            case 'pressure'
                plot(sensorAx, t, state.stimulus.pressure_psi, 'LineWidth', 1.4);
                ylabel(sensorAx, 'Pressure (PSI)');
                legendItems = {'Pressure'};
            case 'flow'
                plot(sensorAx, t, state.stimulus.flow_gpm, 'LineWidth', 1.4);
                ylabel(sensorAx, 'Flow (GPM)');
                legendItems = {'Flow'};
            case 'vibration'
                plot(sensorAx, t, state.stimulus.vibration_g, 'LineWidth', 1.4);
                ylabel(sensorAx, 'Vibration (g)');
                legendItems = {'Vibration'};
            otherwise
                plot(sensorAx, t, state.stimulus.pressure_psi, 'LineWidth', 1.1);
                plot(sensorAx, t, state.stimulus.flow_gpm, 'LineWidth', 1.1);
                yyaxis(sensorAx, 'right');
                plot(sensorAx, t, state.stimulus.vibration_g, 'LineWidth', 1.0);
                ylabel(sensorAx, 'Vibration (g)');
                yyaxis(sensorAx, 'left');
                ylabel(sensorAx, 'Pressure PSI / Flow GPM');
                legendItems = {'Pressure', 'Flow', 'Vibration'};
        end
        leakX = activeLeakMarker();
        if isfinite(leakX)
            xline(sensorAx, leakX, 'Color', [0.85 0.15 0.12], 'LineWidth', 1.3);
            legendItems{end+1} = 'Leak transient';
        end
        title(sensorAx, sprintf('Oil Rig Digital Twin: %s to FPGA', channelDrop.Value));
        legend(sensorAx, legendItems, 'Location', 'northwest');
        grid(sensorAx, 'on');
        hold(sensorAx, 'off');
    end

    function updateFpgaPlots()
        trace = state.trace;
        cla(pipelineAx);
        yyaxis(pipelineAx, 'left');
        stairs(pipelineAx, trace.cycle, trace.mode, 'LineWidth', 1.2);
        ylim(pipelineAx, [-0.2 2.2]);
        yticks(pipelineAx, [0 1 2]);
        ylabel(pipelineAx, 'Mode');
        yyaxis(pipelineAx, 'right');
        plot(pipelineAx, trace.cycle, trace.current_mad, 'LineWidth', 1.0);
        if ismember('cfg_t_low', trace.Properties.VariableNames)
            hold(pipelineAx, 'on');
            yline(pipelineAx, median(trace.cfg_t_low), '--', 'T low', 'Color', [0.85 0.45 0.10]);
            yline(pipelineAx, median(trace.cfg_t_high), ':', 'T high', 'Color', [0.65 0.15 0.10]);
            hold(pipelineAx, 'off');
        end
        ylabel(pipelineAx, 'MAD');
        title(pipelineAx, 'Adaptive Compression Decision');
        grid(pipelineAx, 'on');

        inputCount = sum(trace.input_fire);
        outputBytes = sum(trace.m_axis_tvalid);
        rawBytes = inputCount * 2;
        compressedBytes = max(outputBytes, 1);
        cla(bandwidthAx);
        bar(bandwidthAx, categorical({'Raw sensor bytes', 'TCC output bytes'}), ...
            [rawBytes compressedBytes], 0.55);
        title(bandwidthAx, sprintf('Compression ratio %.2fx', rawBytes / compressedBytes));
        ylabel(bandwidthAx, 'Bytes');
        grid(bandwidthAx, 'on');
    end

    function updateMetrics()
        trace = state.trace;
        packets = state.packets;
        inputCount = sum(trace.input_fire);
        outputBytes = sum(trace.m_axis_tvalid);
        rawBytes = max(inputCount * 2, 1);
        ratio = rawBytes / max(outputBytes, 1);
        latestMode = trace.mode(find(trace.input_fire, 1, 'last'));
        latestQ = trace.q_shift(find(trace.input_fire, 1, 'last'));
        maxFifo = max(trace.fifo_level);
        overflow = any(trace.overflow ~= 0);
        packetCount = height(packets);
        crcOk = ~isempty(packets) && all(packets.crcPass);
        packetCycles = trace.cycle(trace.m_axis_tlast == 1);
        if isempty(packetCycles)
            latencyText = 'LATENCY: pending';
        else
            latencyText = sprintf('LATENCY: %d cyc', max(packetCycles) - min(trace.cycle(trace.input_fire == 1)));
        end

        modeLabel.Text = sprintf('MODE: %s', modeName(latestMode));
        qLabel.Text = sprintf('Q: %d', latestQ);
        ratioLabel.Text = sprintf('RATIO: %.2fx', ratio);
        packetLabel.Text = sprintf('PACKETS: %d', packetCount);
        crcLabel.Text = sprintf('CRC: %s', passText(crcOk));
        fifoLabel.Text = sprintf('FIFO: max %d %s', maxFifo, ternary(overflow, 'OVF', 'OK'));
        latencyLabel.Text = latencyText;
        sampleLabel.Text = sprintf('SAMPLES: %d', inputCount);
    end

    function showPacketHex()
        if isempty(state.packets)
            packetConsole.Value = {'No packet decode yet.'};
            return;
        end
        lines = strings(0, 1);
        lines(end+1) = "Decoded CCSDS packet stream";
        lines(end+1) = "----------------------------------------";
        maxPackets = min(height(state.packets), 24);
        for i = 1:maxPackets
            p = state.packets(i, :);
            lines(end+1) = sprintf( ...
                'PKT %02d | APID 0x%03X | SEQ %03d | MODE %-9s | Q %d | PAYLOAD %3d | CRC %s', ...
                p.packetId, p.apid, p.sequence, modeName(p.mode), p.qShift, ...
                p.payloadBytes, passText(p.crcPass));
            lines(end+1) = sprintf('  %s%s', char(p.hexPreview), ...
                ternary(p.totalBytes > 16, ' ...', ''));
        end
        if height(state.packets) > maxPackets
            lines(end+1) = sprintf('... %d more packets in %s', ...
                height(state.packets) - maxPackets, state.paths.packetCsv);
        end
        packetConsole.Value = cellstr(lines);
    end

    function openWaveform()
        if isempty(state.paths) || ~isfield(state.paths, 'vcdFile') || ~exist(state.paths.vcdFile, 'file')
            packetConsole.Value = {'Run the FPGA simulation first. The VCD file has not been created yet.'};
            return;
        end
        [cmd, manualCmd] = gtkwaveCommand(repoRoot, state.paths.vcdFile);
        [status, msg] = system(cmd);
        if status ~= 0
            packetConsole.Value = [ ...
                "GTKWave launch failed."; ...
                splitlines(string(msg)); ...
                "Manual command:"; ...
                string(manualCmd)];
        else
            packetConsole.Value = { ...
                'GTKWave launch requested.', ...
                'If the window does not appear, run this from a Windows terminal:', ...
                manualCmd, ...
                'WSL log: /tmp/tcc_gtkwave.log'};
        end
    end

    function setPendingMetrics()
        modeLabel.Text = 'MODE: pending';
        qLabel.Text = 'Q: pending';
        ratioLabel.Text = 'RATIO: pending';
        packetLabel.Text = 'PACKETS: pending';
        crcLabel.Text = 'CRC: pending';
        fifoLabel.Text = 'FIFO: pending';
        latencyLabel.Text = 'LATENCY: pending';
        sampleLabel.Text = sprintf('SAMPLES: %s', sampleDrop.Value);
    end

    function setLamps(active)
        for idx = 1:numel(lamps)
            if active(idx)
                lamps(idx).BackgroundColor = [0.08 0.50 0.28];
            else
                lamps(idx).BackgroundColor = [0.21 0.23 0.27];
            end
        end
    end

    function leakX = activeLeakMarker()
        if state.continuous
            leakX = state.leakEventTimeSec;
        else
            leakX = leakStart.Value;
        end
        if isempty(state.stimulus) || ~isfinite(leakX)
            leakX = Inf;
            return;
        end
        tMin = min(state.stimulus.time_s);
        tMax = max(state.stimulus.time_s);
        if leakX < tMin || leakX > tMax
            leakX = Inf;
        end
    end

    function closeDemo()
        try
            if ~isempty(state.demoTimer) && isvalid(state.demoTimer)
                stop(state.demoTimer);
                delete(state.demoTimer);
            end
        catch
        end
        delete(fig);
    end

end

function label = metricLabel(parent, text)
label = uilabel(parent, 'Text', text, ...
    'FontColor', [0.90 0.93 0.96], ...
    'BackgroundColor', [0.14 0.16 0.20], ...
    'HorizontalAlignment', 'center', ...
    'FontWeight', 'bold');
end

function [ok, msg] = runIcarus(repoRoot, paths, rebuild)
if nargin < 3
    rebuild = true;
end
cmd = icarusCommand(repoRoot, paths, rebuild);
[status, msg] = system(cmd);
ok = status == 0;
end

function cmd = icarusCommand(repoRoot, paths, rebuild)
stimRel = unixRel(paths.memFile, repoRoot);
traceRel = unixRel(paths.traceCsv, repoRoot);
packetRel = unixRel(paths.packetCsv, repoRoot);
summaryRel = unixRel(paths.summaryTxt, repoRoot);
vcdRel = unixRel(paths.vcdFile, repoRoot);

if rebuild
    buildCmd = 'iverilog -g2012 -o sim/tb_tcc_matlab_driven rtl/*.v tb/tb_tcc_matlab_driven.v && ';
else
    buildCmd = '';
end

bashCmd = sprintf(['cd %s && mkdir -p demo/generated sim && ' ...
    buildCmd ...
    'vvp sim/tb_tcc_matlab_driven +STIM=%s +TRACE=%s +PACKETS=%s +SUMMARY=%s +VCD=%s'], ...
    shquote(toUnixPath(repoRoot)), shquote(stimRel), shquote(traceRel), ...
    shquote(packetRel), shquote(summaryRel), shquote(vcdRel));

if ispc
    cmd = sprintf('wsl -d Ubuntu -- bash -lc %s', winquote(bashCmd));
else
    cmd = sprintf('bash -lc %s', shquote(bashCmd));
end
end

function [cmd, manualCmd] = gtkwaveCommand(repoRoot, vcdFile)
vcdRel = unixRel(vcdFile, repoRoot);
bashCmd = sprintf('cd %s && nohup gtkwave %s >/tmp/tcc_gtkwave.log 2>&1 &', ...
    shquote(toUnixPath(repoRoot)), shquote(vcdRel));
if ispc
    cmd = sprintf('wsl.exe -d Ubuntu -- bash -lc %s', winquote(bashCmd));
    manualCmd = sprintf('wsl.exe -d Ubuntu -- bash -lc %s', winquote(sprintf('cd %s && gtkwave %s', shquote(toUnixPath(repoRoot)), shquote(vcdRel))));
else
    cmd = sprintf('bash -lc %s', shquote(bashCmd));
    manualCmd = sprintf('bash -lc %s', shquote(sprintf('cd %s && gtkwave %s', shquote(toUnixPath(repoRoot)), shquote(vcdRel))));
end
end

function rel = unixRel(pathValue, repoRoot)
pathValue = char(pathValue);
repoRoot = char(repoRoot);
if startsWith(lower(pathValue), lower(repoRoot))
    rel = pathValue(numel(repoRoot)+2:end);
else
    rel = pathValue;
end
rel = strrep(rel, '\', '/');
end

function out = toUnixPath(pathValue)
pathValue = char(pathValue);
prefixes = {'\\wsl.localhost\Ubuntu', '\\wsl$\Ubuntu'};
out = pathValue;
for i = 1:numel(prefixes)
    prefix = prefixes{i};
    if startsWith(lower(pathValue), lower(prefix))
        out = pathValue(numel(prefix)+1:end);
        out = strrep(out, '\', '/');
        if isempty(out)
            out = '/';
        end
        return;
    end
end
out = strrep(out, '\', '/');
end

function q = shquote(s)
s = char(s);
q = ['''' strrep(s, '''', '''"''"''') ''''];
end

function q = winquote(s)
s = char(s);
q = ['"' strrep(s, '"', '\"') '"'];
end

function name = modeName(modeValue)
modeValue = double(modeValue);
switch modeValue
    case 0
        name = 'lossless detail';
    case 1
        name = 'stable lossy';
    case 2
        name = 'heavy lossy';
    otherwise
        name = 'unknown';
end
end

function text = passText(value)
if logical(value)
    text = 'PASS';
else
    text = 'FAIL';
end
end

function out = ternary(cond, a, b)
if logical(cond)
    out = a;
else
    out = b;
end
end

function text = stageCaption(idx)
captions = {'MAD', 'Q shift', 'delta', 'bytes', 'packet', 'AXI'};
text = captions{idx};
end
