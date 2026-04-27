function packets = decode_tcc_packets(packetCsvPath, varargin)
%DECODE_TCC_PACKETS Decode packet bytes emitted by tb_tcc_matlab_driven.v.
%
% packets = decode_tcc_packets(packetCsvPath) returns one row per CCSDS
% packet with APID, sequence, mode, payload length, and CRC status.

repoRoot = fileparts(fileparts(mfilename('fullpath')));
defaultPacketCsv = fullfile(repoRoot, 'demo', 'generated', 'fpga_packets.csv');
if nargin < 1 || isempty(packetCsvPath)
    packetCsvPath = defaultPacketCsv;
end

p = inputParser;
addParameter(p, 'OutFile', '', @(x) ischar(x) || isstring(x));
addParameter(p, 'Quiet', false, @(x) islogical(x) || isnumeric(x));
parse(p, varargin{:});

packetCsvPath = char(packetCsvPath);
outFile = char(p.Results.OutFile);
quiet = logical(p.Results.Quiet);

if ~exist(packetCsvPath, 'file')
    error('Packet CSV not found: %s', packetCsvPath);
end

byteTable = readtable(packetCsvPath);
if isempty(byteTable)
    packets = table();
    return;
end

required = {'packet_id', 'byte_index', 'cycle', 'byte_dec', 'tlast'};
for k = 1:numel(required)
    if ~ismember(required{k}, byteTable.Properties.VariableNames)
        error('Packet CSV is missing required column: %s', required{k});
    end
end

byteTable = sortrows(byteTable, {'packet_id', 'byte_index'});
ids = unique(byteTable.packet_id);

packetId = zeros(numel(ids), 1);
apid = zeros(numel(ids), 1);
sequence = zeros(numel(ids), 1);
seqFlags = zeros(numel(ids), 1);
mode = zeros(numel(ids), 1);
qShift = zeros(numel(ids), 1);
timestamp = zeros(numel(ids), 1);
payloadBytes = zeros(numel(ids), 1);
totalBytes = zeros(numel(ids), 1);
startCycle = zeros(numel(ids), 1);
endCycle = zeros(numel(ids), 1);
crcExpected = zeros(numel(ids), 1);
crcCalculated = zeros(numel(ids), 1);
crcPass = false(numel(ids), 1);
hexPreview = strings(numel(ids), 1);

for i = 1:numel(ids)
    rows = byteTable(byteTable.packet_id == ids(i), :);
    bytes = uint8(rows.byte_dec);

    packetId(i) = ids(i);
    totalBytes(i) = numel(bytes);
    startCycle(i) = rows.cycle(1);
    endCycle(i) = rows.cycle(end);
    hexPreview(i) = join(compose('%02X', bytes(1:min(16, end))), ' ');

    if numel(bytes) < 13
        apid(i) = NaN;
        sequence(i) = NaN;
        seqFlags(i) = NaN;
        mode(i) = NaN;
        qShift(i) = NaN;
        timestamp(i) = NaN;
        payloadBytes(i) = NaN;
        crcExpected(i) = NaN;
        crcCalculated(i) = NaN;
        crcPass(i) = false;
        continue;
    end

    b = double(bytes);
    apid(i) = bitshift(bitand(b(1), 7), 8) + b(2);
    seqFlags(i) = bitshift(b(3), -6);
    sequence(i) = bitshift(bitand(b(3), 63), 8) + b(4);

    timestamp(i) = bitshift(b(7), 24) + bitshift(b(8), 16) ...
        + bitshift(b(9), 8) + b(10);

    modeByte = b(11);
    mode(i) = bitshift(modeByte, -6);
    qShift(i) = bitand(bitshift(modeByte, -2), 15);

    payloadBytes(i) = numel(bytes) - 6 - 5 - 2;
    crcExpected(i) = bitshift(b(end-1), 8) + b(end);
    crcCalculated(i) = crc_ccitt_false(b(1:end-2));
    crcPass(i) = crcExpected(i) == crcCalculated(i);
end

packets = table(packetId, apid, sequence, seqFlags, mode, qShift, ...
    timestamp, payloadBytes, totalBytes, startCycle, endCycle, ...
    crcExpected, crcCalculated, crcPass, hexPreview);

if ~isempty(outFile)
    fid = fopen(outFile, 'w');
    if fid < 0
        error('Could not write packet decode file: %s', outFile);
    end
    cleanup = onCleanup(@() fclose(fid));
    fprintf(fid, 'TCC packet decode\n');
    fprintf(fid, 'Source: %s\n\n', packetCsvPath);
    for i = 1:height(packets)
        fprintf(fid, 'Packet %d: APID=0x%03X SEQ=%d MODE=%d Q=%d payload=%d bytes CRC=%s\n', ...
            packets.packetId(i), packets.apid(i), packets.sequence(i), ...
            packets.mode(i), packets.qShift(i), packets.payloadBytes(i), ...
            pass_text(packets.crcPass(i)));
        fprintf(fid, '  HEX: %s%s\n', char(packets.hexPreview(i)), ...
            ternary(packets.totalBytes(i) > 16, ' ...', ''));
    end
    clear cleanup;
end

if ~quiet
    disp(packets(:, {'packetId', 'apid', 'sequence', 'mode', 'qShift', ...
        'payloadBytes', 'totalBytes', 'crcPass'}));
end

end

function crc = crc_ccitt_false(bytes)
crc = hex2dec('FFFF');
poly = hex2dec('1021');
for k = 1:numel(bytes)
    crc = bitxor(crc, bitshift(double(bytes(k)), 8));
    for bitIdx = 1:8
        if bitand(crc, hex2dec('8000')) ~= 0
            crc = bitxor(bitshift(crc, 1), poly);
        else
            crc = bitshift(crc, 1);
        end
        crc = bitand(crc, hex2dec('FFFF'));
    end
end
end

function text = pass_text(pass)
if pass
    text = 'PASS';
else
    text = 'FAIL';
end
end

function out = ternary(cond, a, b)
if cond
    out = a;
else
    out = b;
end
end
