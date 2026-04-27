% =========================================================================
% FINAL DIGITAL TWIN BUILDER: OIL RIG SENSORS (Pressure, Flow, Vibration)
% =========================================================================
% This script builds a complete Simulink model for FPGA testing.
% It generates 3 sensor streams:
% 1. Pressure (1500 PSI) with Leak Fault logic.
% 2. Flow Rate (500 GPM) with inverse Leak logic.
% 3. Vibration (120 Hz) with DC Bias for uint16 compatibility.
% =========================================================================

clc; clear; close all;
modelName = 'OilRig_FPGA_Final_V2';

% --- Cleanup Old Model ---
if bdIsLoaded(modelName)
    close_system(modelName, 0);
end
new_system(modelName);
open_system(modelName);

% --- Simulation Parameters ---
Ts = 0.001;               % Sample Time (1kHz)
RemoteIP = '192.168.1.10'; 
RemotePort = 50000;

fprintf('Building Digital Twin: %s...\n', modelName);

try
    % =====================================================================
    % 1. PRESSURE SENSOR SUBSYSTEM (Channel 1)
    % =====================================================================
    % Physics: Constant Pressure + Pump Ripple + Noise + Leak Event
    
    add_block('simulink/Sources/Constant', [modelName '/P_Base'], 'Position', [50, 50, 100, 80], 'Value', '1500');
    add_block('simulink/Sources/Sine Wave', [modelName '/P_Pump'], 'Position', [50, 150, 100, 180], 'Amplitude', '20', 'Frequency', '2*pi*20', 'SampleTime', num2str(Ts));
    
    % Noise: Using correct 'Cov' and 'Ts' params for Band-Limited White Noise
    add_block('simulink/Sources/Band-Limited White Noise', [modelName '/P_Noise'], 'Position', [50, 250, 100, 280], 'Cov', '5', 'Seed', '23', 'Ts', num2str(Ts));
    
    % Fault: Leak drops pressure by 500 PSI at t=30
    add_block('simulink/Sources/Step', [modelName '/Fault_P'], 'Position', [50, 350, 100, 380], 'Time', '30', 'After', '-500', 'SampleTime', num2str(Ts));

    % Math & Scaling
    add_block('simulink/Math Operations/Add', [modelName '/P_Sum'], 'Position', [250, 100, 280, 300], 'Inputs', '+++');
    add_block('simulink/Math Operations/Add', [modelName '/P_Total'], 'Position', [350, 180, 380, 220], 'Inputs', '++');
    add_block('simulink/Math Operations/Gain', [modelName '/P_Gain'], 'Position', [450, 190, 500, 220], 'Gain', '20');
    
    % ADC: Convert to uint16 (Unsigned)
    add_block('simulink/Signal Attributes/Data Type Conversion', [modelName '/P_ADC'], 'Position', [550, 185, 610, 225], 'OutDataTypeStr', 'uint16', 'RndMeth', 'Nearest');

    % Wiring Channel 1
    add_line(modelName, 'P_Base/1', 'P_Sum/1');
    add_line(modelName, 'P_Pump/1', 'P_Sum/2');
    add_line(modelName, 'P_Noise/1', 'P_Sum/3');
    add_line(modelName, 'P_Sum/1', 'P_Total/1');
    add_line(modelName, 'Fault_P/1', 'P_Total/2');
    add_line(modelName, 'P_Total/1', 'P_Gain/1');
    add_line(modelName, 'P_Gain/1', 'P_ADC/1');

    % =====================================================================
    % 2. FLOW SENSOR SUBSYSTEM (Channel 2) - *NEW*
    % =====================================================================
    % Physics: Constant Flow + Fault (Flow INCREASES during leak)
    
    add_block('simulink/Sources/Constant', [modelName '/Q_Base'], 'Position', [50, 500, 100, 530], 'Value', '500');
    
    % Fault: Flow INCREASES by 200 GPM at t=30 (Inverse of pressure)
    add_block('simulink/Sources/Step', [modelName '/Fault_Q'], 'Position', [50, 600, 100, 630], 'Time', '30', 'After', '200', 'SampleTime', num2str(Ts));
    
    % Math & Scaling
    add_block('simulink/Math Operations/Add', [modelName '/Q_Sum'], 'Position', [250, 500, 280, 630], 'Inputs', '++');
    add_block('simulink/Math Operations/Gain', [modelName '/Q_Gain'], 'Position', [450, 550, 500, 580], 'Gain', '10'); % 500 * 10 = 5000 counts
    
    % ADC: uint16
    add_block('simulink/Signal Attributes/Data Type Conversion', [modelName '/Q_ADC'], 'Position', [550, 545, 610, 585], 'OutDataTypeStr', 'uint16', 'RndMeth', 'Nearest');

    % Wiring Channel 2
    add_line(modelName, 'Q_Base/1', 'Q_Sum/1');
    add_line(modelName, 'Fault_Q/1', 'Q_Sum/2');
    add_line(modelName, 'Q_Sum/1', 'Q_Gain/1');
    add_line(modelName, 'Q_Gain/1', 'Q_ADC/1');

    % =====================================================================
    % 3. VIBRATION SENSOR SUBSYSTEM (Channel 3)
    % =====================================================================
    % Physics: 120Hz Motor Harmonics + BIAS to fix negative numbers
    
    add_block('simulink/Sources/Sine Wave', [modelName '/V_Motor'], 'Position', [50, 750, 100, 780], 'Amplitude', '0.1', 'Frequency', '2*pi*120', 'SampleTime', num2str(Ts));
    add_block('simulink/Math Operations/Gain', [modelName '/V_Gain'], 'Position', [200, 750, 250, 780], 'Gain', '10000');
    
    % BIAS: Add 2000 to center the signal so it fits in uint16
    add_block('simulink/Sources/Constant', [modelName '/V_Bias'], 'Position', [200, 820, 250, 850], 'Value', '2000');
    add_block('simulink/Math Operations/Add', [modelName '/V_Sum'], 'Position', [350, 750, 380, 850], 'Inputs', '++');
    
    % ADC: uint16
    add_block('simulink/Signal Attributes/Data Type Conversion', [modelName '/V_ADC'], 'Position', [550, 785, 610, 825], 'OutDataTypeStr', 'uint16', 'RndMeth', 'Nearest');

    % Wiring Channel 3
    add_line(modelName, 'V_Motor/1', 'V_Gain/1');
    add_line(modelName, 'V_Gain/1', 'V_Sum/1');
    add_line(modelName, 'V_Bias/1', 'V_Sum/2');
    add_line(modelName, 'V_Sum/1', 'V_ADC/1');

    % =====================================================================
    % 4. OUTPUT & CONNECTIVITY
    % =====================================================================
    
    % Mux: Combine 3 signals (P, Q, V)
    add_block('simulink/Signal Routing/Mux', [modelName '/Sensor_Mux'], 'Position', [700, 150, 710, 850], 'Inputs', '3', 'DisplayOption', 'bar');

    % Check for Instrument Control Toolbox (UDP)
    if license('test', 'Instrument_Control_Toolbox')
        add_block('instrumentlib/UDP Send', [modelName '/UDP_Tx'], ...
                  'Position', [850, 480, 950, 530], ...
                  'RemoteIPAddress', RemoteIP, ...
                  'RemotePort', num2str(RemotePort));
    else
        % Fallback to Scope if no toolbox
        add_block('simulink/Sinks/Scope', [modelName '/UDP_Tx'], 'Position', [850, 480, 900, 520]);
        warning('Instrument Control Toolbox missing. Using Scope for visualization.');
    end
    
    % Wiring Output
    add_line(modelName, 'P_ADC/1', 'Sensor_Mux/1');
    add_line(modelName, 'Q_ADC/1', 'Sensor_Mux/2');
    add_line(modelName, 'V_ADC/1', 'Sensor_Mux/3');
    add_line(modelName, 'Sensor_Mux/1', 'UDP_Tx/1');

    % --- FINAL CONFIGURATION ---
    % Force Solver to Fixed-Step for FPGA compatibility
    set_param(modelName, 'Solver', 'FixedStepDiscrete');
    set_param(modelName, 'FixedStep', num2str(Ts));
    set_param(modelName, 'StopTime', '60'); % Run for 60 seconds to see the fault

    % Configure Scope Layout (3 Vertical Panes)
    try 
        set_param([modelName '/UDP_Tx'], 'LayoutDimensions', [3, 1]);
    catch
        % Sometimes fails if block is not technically open yet, harmless error
    end

    % Arrange and Save
    Simulink.BlockDiagram.arrangeSystem(modelName);
    save_system(modelName);
    
    fprintf('SUCCESS! Model "%s" created with Pressure, Flow, and Vibration.\n', modelName);
    fprintf('Open the model and click RUN.\n');

catch ME
    fprintf('ERROR: %s\n', ME.message);
    fprintf('Check the line number above to see which block failed.\n');
end