%% DAQ Data Analysis Script
clear; clc; close all;

% USER SETTINGS
NUM_PEAKS      = 1;     % change to show more/fewer peaks
FREQ_LOG_SCALE = true;  % log scale on frequency axis

% Load most recent data file
data_dir = 'E:\DAQ Data\';
files = dir(fullfile(data_dir, 'data*.mat'));
[~, idx] = max([files.datenum]);
filepath = fullfile(data_dir, files(idx).name);
load(filepath);
fprintf('Loaded: %s\n', files(idx).name);

% Setup
ch0_V = double(ch0_V);  % calibrated voltage in V
fs    = double(sample_rate);

% Remove DC offset
ch0_V = ch0_V - mean(ch0_V);
max(ch0_V)
min(ch0_V)

N = length(ch0_V);
t = (0:N-1) / fs * 1000;  % ms

fprintf('Samples: %d | Duration: %.1f ms | Fs: %d SPS\n', N, t(end), fs);
fprintf('Peak voltage: %.4f V\n', max(abs(ch0_V)));

% Figure 1 — Time Domain
figure('Name', 'Time Domain', 'Position', [100 100 1400 500])

subplot(1,2,1)
plot(t, ch0_V, 'b-', 'LineWidth', 0.5)
xlabel('Time (ms)'); ylabel('Voltage (V)')
title('Full Capture — Time Domain')
grid on

subplot(1,2,2)
mask = t <= 5;

t_zoom = t(mask);
v_zoom = ch0_V(mask);

plot(t_zoom, v_zoom, 'b-', 'LineWidth', 1.5)
hold on
plot(t_zoom, v_zoom, 'ro', 'MarkerSize', 4)

% Compute dynamic ylim with ±10% margin
vmin = min(v_zoom);
vmax = max(v_zoom);
vrange = vmax - vmin;
margin = 0.10 * vrange;

ylim([vmin - margin, vmax + margin])

xlabel('Time (ms)'); ylabel('Voltage (V)')
title('Zoomed — First 5ms')
grid on
% Figure 2 — Frequency Domain
figure('Name', 'Frequency Domain')

nfft  = 2^nextpow2(N);
f     = (0:nfft/2-1) * fs / nfft / 1000;  % kHz
X     = fft(ch0_V, nfft);
X_mag = abs(X(1:nfft/2)) * 2 / N;
X_dB  = 20*log10(X_mag + eps);

if FREQ_LOG_SCALE
    semilogx(f, X_dB, 'b-', 'LineWidth', 0.8)
else
    plot(f, X_dB, 'b-', 'LineWidth', 0.8)
end
xlabel('Frequency (kHz)'); ylabel('Magnitude (dB)')
title(sprintf('Frequency Spectrum — Top %d Peaks', NUM_PEAKS))
grid on
xlim([0.1 fs/2/1000])

[pks, locs] = findpeaks(X_dB, ...
    'MinPeakHeight',    max(X_dB) - 60, ...
    'MinPeakDistance',  round(nfft * 50 / fs), ...
    'SortStr',          'descend', ...
    'NPeaks',           NUM_PEAKS);

hold on
plot(f(locs), pks, 'rv', 'MarkerSize', 12, 'MarkerFaceColor', 'r')
for k = 1:length(locs)
    text(f(locs(k)), pks(k) + 4, ...
        sprintf('%.3f kHz\n%.1f dB', f(locs(k)), pks(k)), ...
        'HorizontalAlignment', 'center', ...
        'FontSize', 9, 'Color', 'red', 'FontWeight', 'bold')
end
hold off

% Print summary
fprintf('\n--- Top %d Peaks ---\n', NUM_PEAKS)
for k = 1:length(locs)
    fprintf('Peak %d: %.4f kHz @ %.1f dB\n', k, f(locs(k)), pks(k))
end