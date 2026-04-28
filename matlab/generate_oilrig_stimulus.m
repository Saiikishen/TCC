function [stimulus, paths] = generate_oilrig_stimulus(varargin)
%GENERATE_OILRIG_STIMULUS Create oil-rig sensor data for the TCC RTL demo.
%
% The function writes two files:
%   1. oilrig_timeseries.csv: wide MATLAB-friendly sensor table
%   2. oilrig_<channel>.mem: whitespace-delimited RTL stimulus
%
% RTL stimulus columns:
%   sample_index channel_id sample_u16 fault_active

repoRoot = fileparts(fileparts(mfilename('fullpath')));
defaultOut = fullfile(repoRoot, 'demo', 'generated');

p = inputParser;
addParameter(p, 'OutputDir', defaultOut, @(x) ischar(x) || isstring(x));
addParameter(p, 'Channel', 'pressure', @(x) ischar(x) || isstring(x));
addParameter(p, 'SampleRateHz', 1000, @(x) isnumeric(x) && isscalar(x) && x > 0);
addParameter(p, 'SampleCount', 4096, @(x) isnumeric(x) && isscalar(x) && x > 0);
addParameter(p, 'LeakStartSec', 2.4, @(x) isnumeric(x) && isscalar(x) && x >= 0);
addParameter(p, 'LeakSeverity', 1.0, @(x) isnumeric(x) && isscalar(x) && x >= 0);
addParameter(p, 'LeakHoldSec', 0.45, @(x) isnumeric(x) && isscalar(x) && x >= 0);
addParameter(p, 'LeakRecoverySec', 0.85, @(x) isnumeric(x) && isscalar(x) && x > 0);
addParameter(p, 'NoiseLevel', 1.0, @(x) isnumeric(x) && isscalar(x) && x >= 0);
addParameter(p, 'PressureBasePsi', 1500, @(x) isnumeric(x) && isscalar(x));
addParameter(p, 'FlowBaseGpm', 500, @(x) isnumeric(x) && isscalar(x));
addParameter(p, 'VibrationBaseG', 0.0, @(x) isnumeric(x) && isscalar(x));
addParameter(p, 'Seed', 23, @(x) isnumeric(x) && isscalar(x));
addParameter(p, 'TimeOffsetSec', 0.0, @(x) isnumeric(x) && isscalar(x));
addParameter(p, 'Quiet', false, @(x) islogical(x) || isnumeric(x));
parse(p, varargin{:});

outDir = char(p.Results.OutputDir);
channel = lower(char(p.Results.Channel));
fs = double(p.Results.SampleRateHz);
n = ceil(double(p.Results.SampleCount) / 64) * 64;
leakStartSec = double(p.Results.LeakStartSec);
leakSeverity = double(p.Results.LeakSeverity);
leakHoldSec = double(p.Results.LeakHoldSec);
leakRecoverySec = double(p.Results.LeakRecoverySec);
noiseLevel = double(p.Results.NoiseLevel);
timeOffsetSec = double(p.Results.TimeOffsetSec);
quiet = logical(p.Results.Quiet);

if strcmp(channel, 'flow')
    leakHoldSec = max(leakHoldSec, 0.95);
    leakRecoverySec = max(leakRecoverySec, 1.15);
end

if ~exist(outDir, 'dir')
    mkdir(outDir);
end

rng(double(p.Results.Seed));
t = timeOffsetSec + (0:n-1)' ./ fs;

faultProfile = zeros(n, 1);
shock = zeros(n, 1);
if isfinite(leakStartSec)
    sinceLeak = t - leakStartSec;
    leakMask = sinceLeak >= 0;
    attack = zeros(n, 1);
    attack(leakMask) = 1 - exp(-sinceLeak(leakMask) ./ 0.006);
    decay = exp(-max(sinceLeak - leakHoldSec, 0) ./ leakRecoverySec);
    faultProfile = attack .* decay;
    faultProfile(sinceLeak < 0) = 0;
    shock = exp(-((t - leakStartSec) ./ 0.018) .^ 2);
end
faultActive = faultProfile > 0.03;

pressurePsi = double(p.Results.PressureBasePsi) ...
    + 18.0 .* sin(2*pi*20.*t) ...
    + 4.0 .* sin(2*pi*3.5.*t) ...
    + noiseLevel .* 2.0 .* randn(n, 1) ...
    - leakSeverity .* 520.0 .* faultProfile ...
    - leakSeverity .* 85.0 .* shock;

flowGpm = double(p.Results.FlowBaseGpm) ...
    + 2.0 .* sin(2*pi*2.5.*t + 0.7) ...
    + noiseLevel .* 0.7 .* randn(n, 1) ...
    + leakSeverity .* 220.0 .* faultProfile ...
    + leakSeverity .* 25.0 .* shock;

vibrationG = double(p.Results.VibrationBaseG) ...
    + 0.070 .* sin(2*pi*120.*t) ...
    + 0.018 .* sin(2*pi*240.*t + 0.3) ...
    + noiseLevel .* 0.006 .* randn(n, 1) ...
    + leakSeverity .* faultProfile .* (0.12 .* sin(2*pi*185.*t) + 0.025 .* randn(n, 1)) ...
    + leakSeverity .* 0.18 .* shock;

pressureAdc = clamp_u16(round(pressurePsi .* 20.0));
flowAdc = clamp_u16(round(flowGpm .* 10.0));
vibrationAdc = clamp_u16(round(2000.0 + vibrationG .* 10000.0));

stimulus = table( ...
    t, faultActive, faultProfile, pressurePsi, flowGpm, vibrationG, ...
    pressureAdc, flowAdc, vibrationAdc, ...
    'VariableNames', {'time_s', 'fault_active', 'fault_profile', ...
    'pressure_psi', 'flow_gpm', 'vibration_g', ...
    'pressure_u16', 'flow_u16', 'vibration_u16'});

paths = struct();
paths.outputDir = outDir;
paths.timeseriesCsv = fullfile(outDir, 'oilrig_timeseries.csv');
paths.traceCsv = fullfile(outDir, 'fpga_trace.csv');
paths.packetCsv = fullfile(outDir, 'fpga_packets.csv');
paths.summaryTxt = fullfile(outDir, 'fpga_summary.txt');
paths.decodeTxt = fullfile(outDir, 'packet_decode.txt');
paths.vcdFile = fullfile(outDir, 'tb_tcc_matlab_driven.vcd');

writetable(stimulus, paths.timeseriesCsv);

switch channel
    case 'pressure'
        selectedSamples = pressureAdc;
        selectedChannels = ones(n, 1);
    case 'flow'
        selectedSamples = flowAdc;
        selectedChannels = 2 .* ones(n, 1);
    case 'vibration'
        selectedSamples = vibrationAdc;
        selectedChannels = 3 .* ones(n, 1);
    case 'interleaved'
        selectedSamples = reshape([pressureAdc, flowAdc, vibrationAdc].', [], 1);
        selectedChannels = repmat([1; 2; 3], n, 1);
        faultActive = repelem(faultActive, 3);
    otherwise
        error('Unknown channel "%s". Use pressure, flow, vibration, or interleaved.', channel);
end

paths.memFile = fullfile(outDir, sprintf('oilrig_%s.mem', channel));
fid = fopen(paths.memFile, 'w');
if fid < 0
    error('Could not open stimulus file for writing: %s', paths.memFile);
end

cleanup = onCleanup(@() fclose(fid));
for k = 1:numel(selectedSamples)
    fprintf(fid, '%d %d %d %d\n', ...
        k - 1, selectedChannels(k), selectedSamples(k), double(faultActive(k)));
end
clear cleanup;

if ~quiet
    fprintf('Generated %d RTL samples for channel "%s".\n', numel(selectedSamples), channel);
    fprintf('Stimulus: %s\n', paths.memFile);
    fprintf('Timeseries: %s\n', paths.timeseriesCsv);
end

end

function y = clamp_u16(x)
y = uint16(min(max(double(x), 0), 65535));
end
