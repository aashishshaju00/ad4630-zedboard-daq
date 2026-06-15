%% sysid_analysis_dual.m - Comprehensive System ID from Raw Sweep Data
% ══════════════════════════════════════════════════════════════════════
% Loads raw ADC waveforms from freq_sweep_sysid_dual.py output and performs
% complete system identification from scratch.
%
% INPUT: sysid_final_ch0.mat / sysid_final_ch1.mat (per-channel; run once per file)
%
% PROCESSING PIPELINE:
% 1. ADC calibration (counts → volts)
% 2. Amplitude estimation via THREE independent methods:
% a) Lock-in projection (coherent, exact-frequency)
% b) FFT peak (windowed, bin-grid limited)
% c) Least-squares sine fit (3-param: A, φ, DC)
% 3. Cross-validation between methods
% 4. Time-domain waveform inspection at key frequencies
% 5. Model fitting (magnitude-only, 1-pole and 2-pole)
% 6. AICc model selection
% 7. Wiener compensator parameter recommendation
%
% FIGURES:
% 1. Raw waveform gallery (selected frequencies)
% 2. Bode magnitude + model overlays
% 3. Three-method amplitude comparison
% 4. Fit residuals + measurement uncertainty
% 5. Predicted Wiener compensation response
%
% USAGE:
% 1. Run freq_sweep_sysid_dual.py to capture raw data
% 2. Set DATA_DIR below
% 3. Run this script
% ══════════════════════════════════════════════════════════════════════

clear; clc; close all;

% ═══════════════════════════════════════════════════════════════
% CONFIGURATION
% ═══════════════════════════════════════════════════════════════

DATA_DIR = 'E:\DAQ Data\';
MAT_FILE = fullfile(DATA_DIR, 'sysid_final_ch0.mat');  % or sysid_final_ch1.mat

% Schematic reference
SCHEMATIC_R = 1060; % Ω
SCHEMATIC_C = 2700e-12; % F

% Wiener parameters (current baseline for comparison)
WIENER_EPS = 0.05;

% ═══════════════════════════════════════════════════════════════
% LOAD RAW DATA
% ═══════════════════════════════════════════════════════════════

fprintf('Loading: %s\n', MAT_FILE);
D = load(MAT_FILE);

% freq_sweep_sysid_dual.py saves per-channel files (sysid_final_ch0/ch1.mat),
% each holding ch0_raw, ch1_raw and which channel was driven (active_channel).
% Use the driven channel's waveform and its own calibration constants.
act = double(D.active_channel);
if act == 0
    raw_waveforms = double(D.ch0_raw);   % (n_samples x n_freqs x n_repeats)
    adc_gain      = double(D.gain_ch0);
    adc_offset    = double(D.offset_ch0);
else
    raw_waveforms = double(D.ch1_raw);
    adc_gain      = double(D.gain_ch1);
    adc_offset    = double(D.offset_ch1);
end
freqs       = double(D.freqs_Hz(:));     % column vector (Hz)
fs          = double(D.sample_rate);
n_samples   = double(D.n_samples);
n_freqs     = double(D.n_freqs);
n_repeats   = double(D.n_repeats);
input_vpp   = double(D.input_vpp);
input_vpeak = input_vpp / 2.0;

fprintf(' %d frequencies × %d repeats\n', n_freqs, n_repeats);
fprintf(' %d samples per capture (%.1f s @ %.0f kSPS)\n', ...
    n_samples, n_samples/fs, fs/1e3);
fprintf(' Input: %.1f Vpp (%.2f V peak)\n', input_vpp, input_vpeak);
fprintf('\n');

% ═══════════════════════════════════════════════════════════════
% CALIBRATE: raw counts → voltage
% ═══════════════════════════════════════════════════════════════
% V = raw_counts * adc_gain + adc_offset

fprintf('Calibrating %d waveforms...\n', n_freqs * n_repeats);
volt_waveforms = raw_waveforms * adc_gain + adc_offset;
fprintf(' Done. Range: %.4f to %.4f V\n', ...
    min(volt_waveforms(:)), max(volt_waveforms(:)));
fprintf('\n');

% ═══════════════════════════════════════════════════════════════
% AMPLITUDE & PHASE ESTIMATION - THREE METHODS
% ═══════════════════════════════════════════════════════════════

% Preallocate results: (n_freqs × n_repeats) for each method
amp_lockin = zeros(n_freqs, n_repeats);
amp_fft = zeros(n_freqs, n_repeats);
amp_sinefit = zeros(n_freqs, n_repeats);
phase_lockin = zeros(n_freqs, n_repeats); % degrees
phase_sinefit = zeros(n_freqs, n_repeats);

% Time vector
t = (0:n_samples-1)' / fs;

% Trim parameters for lock-in (skip first/last 2 cycles)
trim_cycles = 2;

% FFT window
win = hann(n_samples);
win_sum = sum(win);

fprintf('Estimating amplitudes (%d × %d = %d waveforms)...\n', ...
    n_freqs, n_repeats, n_freqs * n_repeats);

for fi = 1:n_freqs
    f0 = freqs(fi);

    for ri = 1:n_repeats
        x = volt_waveforms(:, fi, ri);

        % ── Method 1: Lock-in projection 
        trim_samp = round(trim_cycles / f0 * fs);
        if 2*trim_samp < n_samples - 100
            x_trim = x(trim_samp+1 : end-trim_samp);
            t_trim = t(trim_samp+1 : end-trim_samp);
        else
            x_trim = x;
            t_trim = t;
        end
        N_trim = length(x_trim);

        x_ac = x_trim - mean(x_trim);
        ref_cos = cos(2*pi*f0 * t_trim);
        ref_sin = sin(2*pi*f0 * t_trim);

        I_val = 2/N_trim * sum(x_ac .* ref_cos);
        Q_val = 2/N_trim * sum(x_ac .* ref_sin);

        amp_lockin(fi, ri) = sqrt(I_val^2 + Q_val^2);
        phase_lockin(fi, ri) = atan2d(Q_val, I_val);

        % ── Method 2: FFT peak 
        X_fft = fft(x .* win);
        fft_freqs = (0:n_samples-1)' * fs / n_samples;
        mag_fft = 2 * abs(X_fft) / win_sum;
        mag_fft(1) = mag_fft(1) / 2; % DC: no doubling

        % Search within ±2% of f0 (or ±500 Hz minimum)
        search_bw = max(f0 * 0.02, 500);
        mask = (fft_freqs >= f0 - search_bw) & (fft_freqs <= f0 + search_bw);
        if any(mask)
            [pk_val, pk_idx_local] = max(mag_fft(mask));
            idx_all = find(mask);
            amp_fft(fi, ri) = pk_val;
        else
            amp_fft(fi, ri) = 0;
        end

        % ── Method 3: Least-squares sine fit 
        % Model: x(t) = A*cos(2π f0 t) + B*sin(2π f0 t) + C
        % This is LINEAR in [A, B, C] → direct solution via \
        M = [cos(2*pi*f0*t_trim), sin(2*pi*f0*t_trim), ones(N_trim, 1)];
        params = M \ x_ac; % x_ac already has mean removed, but C absorbs residual
        A_fit = params(1);
        B_fit = params(2);

        amp_sinefit(fi, ri) = sqrt(A_fit^2 + B_fit^2);
        phase_sinefit(fi, ri) = atan2d(B_fit, A_fit);
    end

    % Progress
    if mod(fi, 10) == 0 || fi == n_freqs
        fprintf(' %d/%d frequencies processed\n', fi, n_freqs);
    end
end

% ═══════════════════════════════════════════════════════════════
% AVERAGE ACROSS REPEATS
% ═══════════════════════════════════════════════════════════════

amp_lockin_avg = mean(amp_lockin, 2);
amp_lockin_std = std(amp_lockin, 0, 2);
amp_fft_avg = mean(amp_fft, 2);
amp_fft_std = std(amp_fft, 0, 2);
amp_sinefit_avg = mean(amp_sinefit, 2);
amp_sinefit_std = std(amp_sinefit, 0, 2);

% Gain ratios and dB (using FFT as primary - matches previous methodology)
gain_ratio_fft = amp_fft_avg / input_vpeak;
gain_dB_fft = 20 * log10(max(gain_ratio_fft, 1e-10));

gain_ratio_lockin = amp_lockin_avg / input_vpeak;
gain_dB_lockin = 20 * log10(max(gain_ratio_lockin, 1e-10));

gain_ratio_sinefit = amp_sinefit_avg / input_vpeak;
gain_dB_sinefit = 20 * log10(max(gain_ratio_sinefit, 1e-10));

% ═══════════════════════════════════════════════════════════════
% CONSOLE: MEASURED DATA TABLE
% ═══════════════════════════════════════════════════════════════

fprintf('\n');

fprintf('│ Freq(kHz)│ Lock-in (V) ± σ(mV) dB │ FFT pk (V) ± σ(mV) dB │ Sine fit (V) ± σ(mV) dB │\n');

for k = 1:n_freqs
    fprintf('│ %7.1f │ %.4f ±%5.1f %+6.1f dB │ %.4f ±%5.1f %+6.1f dB │ %.4f ±%5.1f %+6.1f dB │\n', ...
        freqs(k)/1e3, ...
        amp_lockin_avg(k), amp_lockin_std(k)*1e3, gain_dB_lockin(k), ...
        amp_fft_avg(k), amp_fft_std(k)*1e3, gain_dB_fft(k), ...
        amp_sinefit_avg(k), amp_sinefit_std(k)*1e3, gain_dB_sinefit(k));
end

% ═══════════════════════════════════════════════════════════════
% FIGURE 1: RAW WAVEFORM GALLERY (selected frequencies)
% ═══════════════════════════════════════════════════════════════
% Visual inspection of actual captured waveforms at key frequencies.
% THIS IS THE MOST IMPORTANT DIAGNOSTIC - look for:
% - Clean sine vs noise/distortion
% - Signal presence vs absence at suspected null frequencies
% - Clipping, DC offset issues

% Select frequencies to inspect
inspect_freqs = [1000, 5000, 10000, 30000, 50000, 54000, 58000, 60000, ...
    62000, 64000, 66000, 68000, 70000, 80000, 100000, 120000];

% Find nearest available frequency for each
inspect_idx = zeros(size(inspect_freqs));
for k = 1:length(inspect_freqs)
    [~, inspect_idx(k)] = min(abs(freqs - inspect_freqs(k)));
end
inspect_idx = unique(inspect_idx, 'stable');
n_inspect = length(inspect_idx);

n_rows = ceil(n_inspect / 4);
n_cols = min(4, n_inspect);

fig1 = figure('Name', 'Waveform Gallery', ...
    'Position', [30 30 1600 200*n_rows + 100], 'Color', [0.97 0.96 0.95]);

for k = 1:n_inspect
    fi = inspect_idx(k);
    f0 = freqs(fi);

    ax = subplot(n_rows, n_cols, k);

    % Show 4 cycles (or 0.5ms minimum) from middle of capture
    n_show = max(round(4 / f0 * fs), round(0.5e-3 * fs));
    start_idx = round(n_samples/2) - round(n_show/2);
    start_idx = max(start_idx, 1);
    end_idx = min(start_idx + n_show - 1, n_samples);
    idx = start_idx:end_idx;

    % Plot first repeat
    t_ms = t(idx) * 1e3;
    x_show = volt_waveforms(idx, fi, 1);

    plot(t_ms, x_show, 'b-', 'LineWidth', 0.8);
    hold on;
    % Show DC-removed version for reference
    x_ac = x_show - mean(x_show);
    plot(t_ms, x_ac, 'r-', 'LineWidth', 0.5, 'Color', [0.8 0.2 0.2 0.4]);

    grid on;
    xlabel('Time (ms)', 'FontSize', 7);
    ylabel('V', 'FontSize', 7);
    title(sprintf('%.0f kHz | A_{LI}=%.3f A_{FFT}=%.3f', ...
        f0/1e3, amp_lockin_avg(fi), amp_fft_avg(fi)), ...
        'FontSize', 8, 'FontWeight', 'bold');

    % Add peak-to-peak annotation
    vpp = max(x_ac) - min(x_ac);
    text(0.02, 0.95, sprintf('Vpp=%.3f', vpp), ...
        'Units', 'normalized', 'FontSize', 7, 'VerticalAlignment', 'top');

    set(ax, 'FontSize', 7);
end

sgtitle(sprintf('Raw Waveform Gallery - %d Selected Frequencies (blue=raw, red=AC)', ...
    n_inspect), 'FontSize', 13, 'FontWeight', 'bold');

% ═══════════════════════════════════════════════════════════════
% FIGURE 2: THREE-METHOD AMPLITUDE COMPARISON
% ═══════════════════════════════════════════════════════════════

fig2 = figure('Name', 'Method Comparison', ...
    'Position', [60 60 1400 700], 'Color', [0.97 0.96 0.95]);

col_lockin = [0.00 0.45 0.70];
col_fft = [0.80 0.15 0.15];
col_sinfit = [0.10 0.55 0.30];
col_schem = [0.55 0.55 0.80];

% ── [Left] Amplitude comparison ──────────────────────────────
subplot(1, 2, 1);
hold on; grid on; box on;

errorbar(freqs/1e3, amp_lockin_avg, amp_lockin_std, 'o-', ...
    'Color', col_lockin, 'MarkerSize', 4, 'LineWidth', 1.2, 'CapSize', 2, ...
    'DisplayName', 'Lock-in');
errorbar(freqs/1e3, amp_fft_avg, amp_fft_std, 's--', ...
    'Color', col_fft, 'MarkerSize', 4, 'LineWidth', 1.2, 'CapSize', 2, ...
    'DisplayName', 'FFT peak');
errorbar(freqs/1e3, amp_sinefit_avg, amp_sinefit_std, '^-.', ...
    'Color', col_sinfit, 'MarkerSize', 4, 'LineWidth', 1, 'CapSize', 2, ...
    'DisplayName', 'Sine fit');

xlabel('Frequency (kHz)', 'FontSize', 11);
ylabel('Amplitude (V peak)', 'FontSize', 11);
title('Three-Method Amplitude Comparison', 'FontSize', 12, 'FontWeight', 'bold');
legend('Location', 'northeast', 'FontSize', 9);

% ── [Right] Percent difference relative to sine fit ──────────
subplot(1, 2, 2);
hold on; grid on; box on;

pct_lockin_vs_sinfit = (amp_lockin_avg - amp_sinefit_avg) ./ ...
    max(amp_sinefit_avg, 1e-10) * 100;
pct_fft_vs_sinfit = (amp_fft_avg - amp_sinefit_avg) ./ ...
    max(amp_sinefit_avg, 1e-10) * 100;

stem(freqs/1e3, pct_lockin_vs_sinfit, 'o', 'Color', col_lockin, ...
    'LineWidth', 1.2, 'MarkerSize', 4, ...
    'DisplayName', 'Lock-in vs Sine fit');
stem(freqs/1e3, pct_fft_vs_sinfit, 's', 'Color', col_fft, ...
    'LineWidth', 1, 'MarkerSize', 4, ...
    'DisplayName', 'FFT vs Sine fit');

yline(0, 'k-', 'LineWidth', 0.5);
xlabel('Frequency (kHz)', 'FontSize', 11);
ylabel('Difference (%)', 'FontSize', 11);
title('Method Differences (relative to sine fit)', 'FontSize', 12, 'FontWeight', 'bold');
legend('Location', 'best', 'FontSize', 9);

sgtitle('Amplitude Estimation Method Cross-Validation', ...
    'FontSize', 14, 'FontWeight', 'bold');

% ═══════════════════════════════════════════════════════════════
% SELECT BEST AMPLITUDE ESTIMATE FOR FITTING
% ═══════════════════════════════════════════════════════════════
% Use FFT peak as primary for model fitting: lock-in and sine fit are
% coherent at the commanded frequency, so a small ADC sample-clock
% offset imposes a sinc attenuation that makes them underestimate
% amplitude off the bin grid, whereas FFT peak tracks the true
% spectral peak (see clock-offset diagnostics below). Lock-in and sine
% fit are retained for cross-validation against the FFT estimate.

amps_fit = amp_fft_avg;
amps_fit_std = amp_fft_std;
method_label = 'FFT peak';

% Flag frequencies where coherent methods diverge from FFT peak
% (Lock-in and sine fit are both vulnerable to ADC clock offset;
%  FFT peak finds the actual spectral peak regardless of exact frequency)
pct_LI_vs_FFT = abs(amp_lockin_avg - amp_fft_avg) ./ max(amp_fft_avg, 1e-10) * 100;
pct_SF_vs_FFT = abs(amp_sinefit_avg - amp_fft_avg) ./ max(amp_fft_avg, 1e-10) * 100;

fprintf('Method agreement diagnostics (FFT peak = reference):\n');
fprintf(' Lock-in vs FFT:   max diff = %.1f%%, mean = %.1f%%\n', ...
    max(pct_LI_vs_FFT), mean(pct_LI_vs_FFT));
fprintf(' Sine fit vs FFT:  max diff = %.1f%%, mean = %.1f%%\n', ...
    max(pct_SF_vs_FFT), mean(pct_SF_vs_FFT));

suspect = find(pct_SF_vs_FFT > 20);
if ~isempty(suspect)
    fprintf(' caution Frequencies where coherent methods diverge >20%% from FFT:\n');
    fprintf('   (Cause: ADC clock offset - sinc attenuation of lock-in/sine fit)\n');
    for k = 1:length(suspect)
        fprintf('   %.1f kHz: SineFit=%.4f V vs FFT=%.4f V (%.0f%% underestimate)\n', ...
            freqs(suspect(k))/1e3, amp_sinefit_avg(suspect(k)), ...
            amp_fft_avg(suspect(k)), pct_SF_vs_FFT(suspect(k)));
    end
end
fprintf('\n');

% ═══════════════════════════════════════════════════════════════
% MONOTONICITY CHECK - IS THE NOTCH REAL?
% ═══════════════════════════════════════════════════════════════

fprintf('Monotonicity check (FFT peak amplitudes):\n');
non_mono = find(diff(amps_fit) > 0);
if isempty(non_mono)
    fprintf(' Amplitude is monotone-decreasing across all frequencies.\n');
    fprintf(' Simple LP model should fit well.\n');
    has_notch = false;
else
    fprintf('  Non-monotone regions detected:\n');
    for k = 1:length(non_mono)
        idx = non_mono(k);
        fprintf(' %.1f -> %.1f kHz: %.4f → %.4f V (increase of %.1f mV)\n', ...
            freqs(idx)/1e3, freqs(idx+1)/1e3, ...
            amps_fit(idx), amps_fit(idx+1), ...
            (amps_fit(idx+1) - amps_fit(idx))*1e3);
    end

    % Check if there's a clear null+recovery pattern
    [min_val, min_idx] = min(amps_fit);
    if min_idx > 1 && min_idx < n_freqs && ...
            amps_fit(min_idx-1) > min_val * 2 && ...
            amps_fit(min(min_idx+3, n_freqs)) > min_val * 2
        fprintf('  NOTCH detected near %.1f kHz (min = %.4f V)\n', ...
            freqs(min_idx)/1e3, min_val);
        fprintf(' A simple 1-pole or 2-pole model CANNOT fit this.\n');
        fprintf(' Check waveform gallery at this frequency.\n');
        has_notch = true;
    else
        has_notch = false;
        fprintf(' Minor non-monotonicity - may be measurement noise.\n');
    end
end
fprintf('\n');

% ═══════════════════════════════════════════════════════════════
% MODEL FITTING - MAGNITUDE ONLY
% ═══════════════════════════════════════════════════════════════
% NOTE: Phase excluded (no trigger alignment in current sweep setup).

fprintf('=== MODEL FITTING (magnitude only, using %s) ===\n\n', method_label);

fc_schematic = 1 / (2 * pi * SCHEMATIC_R * SCHEMATIC_C);

% ── Fit options ──
opts = optimoptions('lsqcurvefit', ...
    'Display', 'off', 'MaxIterations', 5000, ...
    'MaxFunctionEvaluations', 10000, ...
    'TolFun', 1e-14, 'TolX', 1e-14);

% ── Fit 1: Single pole + free gain ──────────────────────────
fprintf('Fit 1: Single pole + gain ...\n');
model_1p = @(p, f) p(2) ./ sqrt(1 + (f./p(1)).^2);

try
    [p1, rss1, res1, ~, ~, ~, J1] = lsqcurvefit( ...
        model_1p, [fc_schematic, amps_fit(1)], freqs, amps_fit, ...
        [1e3, 0.01], [500e3, 10.0], opts);

    fc_1p = p1(1);
    gain_1p = p1(2);
    rmse_1p = sqrt(rss1 / n_freqs);

    % Parameter uncertainty
    s2 = rss1 / (n_freqs - 2);
    try
        C = inv(full(J1'*J1)) * s2;
        fc_1p_err = sqrt(C(1,1));
        gain_1p_err = sqrt(C(2,2));
    catch
        fc_1p_err = NaN; gain_1p_err = NaN;
    end

    fprintf(' fc = %.1f ± %.1f Hz (%.2f kHz)\n', fc_1p, fc_1p_err, fc_1p/1e3);
    fprintf(' G = %.4f ± %.4f V (ratio: %.4f)\n', gain_1p, gain_1p_err, gain_1p/input_vpeak);
    fprintf(' RMSE = %.1f mV (RSS = %.6f)\n', rmse_1p*1e3, rss1);
    fit1_ok = true;
catch ME
    fprintf(' FAILED: %s\n', ME.message);
    fc_1p = NaN; gain_1p = NaN; rss1 = Inf; rmse_1p = Inf;
    res1 = zeros(n_freqs, 1); fit1_ok = false;
end
fprintf('\n');

% ── Fit 2: Two poles + free gain ─────────────────────────────
fprintf('Fit 2: Two poles + gain ...\n');
model_2p = @(p, f) p(3) ./ (sqrt(1 + (f./p(1)).^2) .* sqrt(1 + (f./p(2)).^2));

try
    [p2, rss2, res2, ~, ~, ~, J2] = lsqcurvefit( ...
        model_2p, [fc_schematic, 500e3, amps_fit(1)], freqs, amps_fit, ...
        [1e3, 10e3, 0.01], [500e3, 5e6, 10.0], opts);

    fc1_2p = min(p2(1), p2(2));
    fc2_2p = max(p2(1), p2(2));
    gain_2p = p2(3);
    rmse_2p = sqrt(rss2 / n_freqs);

    s2 = rss2 / (n_freqs - 3);
    try
        C = inv(full(J2'*J2)) * s2;
        fc1_2p_err = sqrt(C(1,1));
        fc2_2p_err = sqrt(C(2,2));
        gain_2p_err = sqrt(C(3,3));
    catch
        fc1_2p_err = NaN; fc2_2p_err = NaN; gain_2p_err = NaN;
    end

    fprintf(' fc1 = %.1f ± %.1f Hz (%.2f kHz)\n', fc1_2p, fc1_2p_err, fc1_2p/1e3);
    fprintf(' fc2 = %.0f ± %.0f Hz (%.1f kHz)\n', fc2_2p, fc2_2p_err, fc2_2p/1e3);
    fprintf(' G = %.4f V (ratio: %.4f)\n', gain_2p, gain_2p/input_vpeak);
    fprintf(' RMSE = %.1f mV (RSS = %.6f)\n', rmse_2p*1e3, rss2);
    fit2_ok = true;
catch ME
    fprintf(' FAILED: %s\n', ME.message);
    fc1_2p = NaN; fc2_2p = NaN; gain_2p = NaN;
    rss2 = Inf; rmse_2p = Inf;
    res2 = zeros(n_freqs, 1); fit2_ok = false;
end
fprintf('\n');

% ── Fit 3: Single pole, gain fixed at input_vpeak ───────────
fprintf('Fit 3: Single pole, fixed gain = %.2f V ...\n', input_vpeak);
model_1pf = @(p, f) input_vpeak ./ sqrt(1 + (f./p(1)).^2);

try
    [p3, rss3, res3] = lsqcurvefit( ...
        model_1pf, [fc_schematic], freqs, amps_fit, [1e3], [500e3], opts);
    fc_1pf = p3(1);
    rmse_1pf = sqrt(rss3 / n_freqs);
    fprintf(' fc = %.1f Hz (%.2f kHz)\n', fc_1pf, fc_1pf/1e3);
    fprintf(' RMSE = %.1f mV\n', rmse_1pf*1e3);
    fit3_ok = true;
catch ME
    fprintf(' FAILED: %s\n', ME.message);
    fc_1pf = NaN; rss3 = Inf; rmse_1pf = Inf;
    res3 = zeros(n_freqs, 1); fit3_ok = false;
end
fprintf('\n');

% ═══════════════════════════════════════════════════════════════
% AICc MODEL SELECTION
% ═══════════════════════════════════════════════════════════════

aicc = @(rss, k, n) n*log(rss/n) + 2*k + 2*k*(k+1)/(n-k-1);

aicc_1pf = aicc(rss3, 1, n_freqs);
aicc_1p = aicc(rss1, 2, n_freqs);
aicc_2p = aicc(rss2, 3, n_freqs);

fprintf('=== MODEL SELECTION (AICc) ===\n');
fprintf(' 1-pole fixed: AICc = %+.1f RMSE = %.1f mV\n', aicc_1pf, rmse_1pf*1e3);
fprintf(' 1-pole free: AICc = %+.1f RMSE = %.1f mV\n', aicc_1p, rmse_1p*1e3);
fprintf(' 2-pole free: AICc = %+.1f RMSE = %.1f mV\n', aicc_2p, rmse_2p*1e3);

delta = aicc_1p - aicc_2p;
fprintf(' ΔAICc (1p vs 2p) = %+.1f → ', delta);
if delta > 2
    best = '2-pole'; fprintf('2-pole is better\n');
else
    best = '1-pole'; fprintf('1-pole is sufficient\n');
end
fprintf('\n');

% ═══════════════════════════════════════════════════════════════
% RECOMMENDED PARAMETERS
% ═══════════════════════════════════════════════════════════════

fprintf('║ RECOMMENDED start_daq_uae.py PARAMETERS ║\n');
if strcmp(best, '1-pole') && fit1_ok
    rec_fc = fc_1p;
    rec_G = gain_1p / input_vpeak;
    fprintf('║ AFE_FC = %.0f ║\n', rec_fc);
    fprintf('║ AFE_G = %.4f ║\n', rec_G);
    fprintf('║ WIENER_EPS = %.2f ║\n', WIENER_EPS);
    fprintf('║ ║\n');
    fprintf('║ Previous: AFE_FC=53500, AFE_G=0.9791 ║\n');
    fprintf('║ Change: Δfc=%+.0f Hz, ΔG=%+.4f ║\n', ...
        rec_fc-53500, rec_G-0.9791);
elseif fit2_ok
    rec_fc = fc1_2p;
    rec_G = gain_2p / input_vpeak;
    fprintf('║ 2-POLE: update start_daq_uae.py Wiener to handle two poles ║\n');
    fprintf('║ AFE_FC1 = %.0f AFE_FC2 = %.0f AFE_G = %.4f ║\n', ...
        fc1_2p, fc2_2p, rec_G);
end

if has_notch
    fprintf('  WARNING: Notch detected in measured data.\n');
    fprintf(' Parametric models above may not adequately capture system behavior.\n');
    fprintf(' Inspect waveform gallery and verify with oscilloscope before\n');
    fprintf(' updating start_daq_uae.py parameters.\n\n');
end

% ═══════════════════════════════════════════════════════════════
% FIGURE 3: BODE MAGNITUDE + MODEL OVERLAYS
% ═══════════════════════════════════════════════════════════════

fig3 = figure('Name', 'Bode Magnitude', ...
    'Position', [50 50 1400 900], 'Color', [0.97 0.96 0.95]);

f_plot = logspace(log10(max(freqs(1)*0.5, 100)), log10(freqs(end)*2), 500);

% ── [Top] Bode plot ──
ax1 = subplot(2, 2, [1 2]);
hold on; grid on; box on;
set(ax1, 'XScale', 'log', 'FontSize', 10);

% All three estimation methods (FFT = primary for fitting)
errorbar(freqs/1e3, amp_fft_avg, amp_fft_std, 'ko', ...
    'MarkerSize', 5, 'MarkerFaceColor', 'k', 'CapSize', 3, ...
    'DisplayName', 'FFT peak ± 1σ (used for fit)');
% plot(freqs/1e3, amp_sinefit_avg, 'g^', 'MarkerSize', 4, ...
%     'DisplayName', 'Sine fit (clock-sensitive)');
% plot(freqs/1e3, amp_lockin_avg, 'bv', 'MarkerSize', 4, ...
%     'DisplayName', 'Lock-in (clock-sensitive)');

% Schematic
H_sch = input_vpeak ./ sqrt(1 + (f_plot / fc_schematic).^2);
semilogx(f_plot/1e3, H_sch, '--', 'Color', col_schem, 'LineWidth', 1.5, ...
    'DisplayName', sprintf('Schematic (fc=%.1f kHz)', fc_schematic/1e3));

% Model fits
if fit1_ok
    semilogx(f_plot/1e3, model_1p([fc_1p, gain_1p], f_plot), '-', ...
        'Color', col_lockin, 'LineWidth', 2.5, ...
        'DisplayName', sprintf('1-pole: fc=%.1f kHz, G=%.3f', fc_1p/1e3, gain_1p));
end
if fit2_ok
    semilogx(f_plot/1e3, model_2p([fc1_2p, fc2_2p, gain_2p], f_plot), '-', ...
        'Color', col_fft, 'LineWidth', 2, ...
        'DisplayName', sprintf('2-pole: %.1f+%.0f kHz', fc1_2p/1e3, fc2_2p/1e3));
end

legend('Location', 'northeast', 'FontSize', 8);
ylabel('Amplitude (V peak)', 'FontSize', 11);
xlabel('Frequency (kHz)', 'FontSize', 11);
title(sprintf('Bode Magnitude - %d points, %d repeats, %s', ...
    n_freqs, n_repeats, method_label), 'FontSize', 12, 'FontWeight', 'bold');
xlim([freqs(1)/1e3 * 0.7, freqs(end)/1e3 * 1.5]);

% ── [Bottom-left] Residuals ──
ax2 = subplot(2, 2, 3);
hold on; grid on; box on;
if fit1_ok
    plot(freqs/1e3, res1*1e3, 'o-', 'Color', col_lockin, 'MarkerSize', 4, ...
        'DisplayName', sprintf('1-pole (RMSE=%.1f mV)', rmse_1p*1e3));
end
if fit2_ok
    plot(freqs/1e3, res2*1e3, 's-', 'Color', col_fft, 'MarkerSize', 4, ...
        'DisplayName', sprintf('2-pole (RMSE=%.1f mV)', rmse_2p*1e3));
end
fill([freqs; flipud(freqs)]/1e3, ...
    [amps_fit_std; -flipud(amps_fit_std)]*1e3, ...
    [0.85 0.85 0.85], 'EdgeColor', 'none', 'FaceAlpha', 0.5, ...
    'DisplayName', '±1σ noise');
yline(0, 'k-', 'LineWidth', 0.5);
xlabel('Frequency (kHz)'); ylabel('Residual (mV)');
title('Magnitude Residuals'); legend('Location', 'best', 'FontSize', 8);

% ── [Bottom-right] Fractional residuals ──
ax3 = subplot(2, 2, 4);
hold on; grid on; box on;
if fit1_ok
    plot(freqs/1e3, res1 ./ max(amps_fit, 1e-6) * 100, 'o-', ...
        'Color', col_lockin, 'MarkerSize', 4, 'DisplayName', '1-pole (%)');
end
if fit2_ok
    plot(freqs/1e3, res2 ./ max(amps_fit, 1e-6) * 100, 's-', ...
        'Color', col_fft, 'MarkerSize', 4, 'DisplayName', '2-pole (%)');
end
yline(0, 'k-', 'LineWidth', 0.5);
xlabel('Frequency (kHz)'); ylabel('Residual (%)');
title('Fractional Residuals'); legend('Location', 'best', 'FontSize', 8);

sgtitle('System Identification - Model Fitting', ...
    'FontSize', 14, 'FontWeight', 'bold');

% ═══════════════════════════════════════════════════════════════
% FIGURE 4: WIENER COMPENSATION PREDICTION
% ═══════════════════════════════════════════════════════════════

if fit1_ok || fit2_ok
    fig4 = figure('Name', 'Wiener Prediction', ...
        'Position', [100 100 1200 500], 'Color', [0.97 0.96 0.95]);

    f_dense = logspace(log10(100), log10(fs/2), 2000)';
    eps2 = WIENER_EPS^2;

    % Old compensator
    H_old = 0.9791 ./ (1 + 1j * f_dense / 53500);
    H_w_old = conj(H_old) ./ (abs(H_old).^2 + eps2);
    H_comb_old = abs(H_old .* H_w_old) * 100;

    % New compensator
    if strcmp(best, '1-pole') && fit1_ok
        G_new = gain_1p / input_vpeak;
        H_new = G_new ./ (1 + 1j * f_dense / fc_1p);
        new_label = sprintf('NEW: fc=%.1f kHz, G=%.4f', fc_1p/1e3, G_new);
    elseif fit2_ok
        G_new = gain_2p / input_vpeak;
        H_new = G_new ./ ((1 + 1j*f_dense/fc1_2p) .* (1 + 1j*f_dense/fc2_2p));
        new_label = sprintf('NEW: 2-pole %.1f+%.0f kHz', fc1_2p/1e3, fc2_2p/1e3);
    end
    H_w_new = conj(H_new) ./ (abs(H_new).^2 + eps2);
    H_comb_new = abs(H_new .* H_w_new) * 100;

    hold on; grid on; box on;
    set(gca, 'XScale', 'log', 'FontSize', 10);

    plot(f_dense/1e3, H_comb_new, '-', 'Color', col_lockin, 'LineWidth', 2.5, ...
        'DisplayName', new_label);
    plot(f_dense/1e3, H_comb_old, '--', 'Color', [0.85 0.55 0.15], ...
        'LineWidth', 2, 'DisplayName', 'OLD: fc=53.5 kHz, G=0.9791');

    yline(100, 'k:', 'LineWidth', 0.8);
    yline(99, ':', 'Color', [0.4 0.7 0.4], 'Label', '99%', 'FontSize', 8);
    yline(95, ':', 'Color', [0.7 0.7 0.4], 'Label', '95%', 'FontSize', 8);

    legend('Location', 'southwest', 'FontSize', 10);
    xlabel('Frequency (kHz)', 'FontSize', 11);
    ylabel('Amplitude Recovery (%)', 'FontSize', 11);
    title(sprintf('Predicted Wiener Recovery (ε = %.2f): New vs Old', WIENER_EPS), ...
        'FontSize', 12, 'FontWeight', 'bold');
    xlim([0.5, fs/2e3]); ylim([50, 102]);
end

%% ═══════════════════════════════════════════════════════════════
%  ADC CLOCK OFFSET CHARACTERIZATION
%  ═══════════════════════════════════════════════════════════════
%  Uses existing sweep data to measure the true ADC sample rate.
%  If fs_actual ≠ fs_nominal, coherent methods (lock-in, sine fit)
%  see a frequency mismatch that grows with f0, producing sinc
%  attenuation. FFT peak is immune (finds the peak wherever it is).

fprintf('\n=== ADC CLOCK OFFSET CHARACTERIZATION ===\n\n');

fs_nominal = fs;   % 500000 Hz (what we told iio_attr)

% ── Test 1: Estimate fs_actual from exact FFT peak bin position ──
%   For each tone at f0 (Siglent), the FFT peak lands at bin k where:
%     k = f0 * N / fs_actual
%   Therefore: fs_actual = f0 * N / k
%   With N=1e6, bin spacing = 0.5 Hz → sub-Hz precision.

fs_estimates = zeros(n_freqs, n_repeats);
peak_bins    = zeros(n_freqs, n_repeats);

for fi = 1:n_freqs
    f0 = freqs(fi);
    for ri = 1:n_repeats
        x = volt_waveforms(:, fi, ri);

        % Use Hann window for clean peak shape
        X = fft(x .* win);
        mag = abs(X(1:n_samples/2+1));

        % Search near expected bin
        k_nominal = round(f0 * n_samples / fs_nominal);
        search = max(k_nominal - 20, 2) : min(k_nominal + 20, length(mag));

        % Parabolic interpolation around peak for sub-bin precision
        [~, local_idx] = max(mag(search));
        k_peak = search(local_idx);

        % Parabolic interpolation using 3 points around peak
        if k_peak > 1 && k_peak < length(mag)
            alpha = log(mag(k_peak-1));
            beta  = log(mag(k_peak));
            gamma = log(mag(k_peak+1));
            delta_k = 0.5 * (alpha - gamma) / (alpha - 2*beta + gamma);
            k_precise = k_peak + delta_k;  % sub-bin peak location
        else
            k_precise = k_peak;
        end

        % Convert bin to fs estimate
        % k_precise = f0 * N / fs_actual  (bins are 0-indexed in math, 1-indexed in MATLAB)
        % MATLAB FFT: bin 1 = DC, bin k = (k-1)*fs/N Hz
        k_zero_indexed = k_precise - 1;   % convert to 0-indexed
        fs_estimates(fi, ri) = f0 * n_samples / k_zero_indexed;
        peak_bins(fi, ri) = k_precise;
    end
end

fs_est_avg = mean(fs_estimates, 2);   % per-frequency average
fs_est_all = fs_estimates(:);          % all estimates flat

% Exclude very low frequencies (bins too close to DC, poor precision)
good_mask = freqs >= 5000;
fs_est_good = fs_estimates(good_mask, :);

fs_actual_mean = mean(fs_est_good(:));
fs_actual_std  = std(fs_est_good(:));
delta_fs = fs_actual_mean - fs_nominal;
ppm_offset = delta_fs / fs_nominal * 1e6;

fprintf('Test 1 - Direct fs estimation from FFT peak bins:\n');
fprintf('  fs_actual = %.3f ± %.3f Hz\n', fs_actual_mean, fs_actual_std);
fprintf('  Δfs       = %+.3f Hz  (%+.2f ppm)\n', delta_fs, ppm_offset);
fprintf('  (Positive = ADC clock runs fast, negative = slow)\n\n');

% ── Test 2: Sinc envelope fit ──
%  The lock-in attenuation should follow:
%    amp_lockin / amp_fft = |sinc(T * f0 * Δfs / fs^2 * pi)|
%  where T = capture duration in seconds.
%  (Using MATLAB sinc which is sinc(x) = sin(pi*x)/(pi*x))

T_capture = n_samples / fs_nominal;   % 2.0 seconds
ratio_LI_FFT = amp_lockin_avg ./ max(amp_fft_avg, 1e-10);

% Fit: find Δfs that best matches the observed ratios
% Model: ratio = |sinc(T * f * Δfs / fs^2)|
%   MATLAB sinc(x) = sin(pi*x)/(pi*x), so argument is T*f*Δfs/fs^2
sinc_model = @(dfs, f) abs(sinc(T_capture * f * dfs / fs_nominal^2));

% Grid search for robustness (sinc has many lobes)
dfs_grid = linspace(-20, 20, 10000);
cost = zeros(size(dfs_grid));
for gi = 1:length(dfs_grid)
    pred = sinc_model(dfs_grid(gi), freqs(good_mask));
    cost(gi) = sum((ratio_LI_FFT(good_mask) - pred).^2);
end
[~, best_gi] = min(cost);
dfs_sinc = dfs_grid(best_gi);

% Refine with fminsearch
refine_cost = @(dfs) sum((ratio_LI_FFT(good_mask) - sinc_model(dfs, freqs(good_mask))).^2);
dfs_sinc = fminsearch(refine_cost, dfs_sinc);
ppm_sinc = dfs_sinc / fs_nominal * 1e6;

fprintf('Test 2 - Sinc envelope fit (lock-in / FFT ratio):\n');
fprintf('  Δfs_sinc  = %+.3f Hz  (%+.2f ppm)\n', dfs_sinc, ppm_sinc);

% Check agreement with Test 1
fprintf('  Agreement with Test 1: %.3f Hz difference\n\n', abs(delta_fs - dfs_sinc));

% ── Test 3: Repeat-to-repeat stability
%  Is the offset constant across captures (fixed crystal) or
%  variable (jitter/drift)?

fprintf('Test 3 - Repeat-to-repeat stability (f ≥ 5 kHz):\n');
for ri = 1:n_repeats
    vals = fs_estimates(good_mask, ri);
    fprintf('  Repeat %d: fs = %.3f ± %.3f Hz  (Δ = %+.3f Hz)\n', ...
        ri, mean(vals), std(vals), mean(vals) - fs_nominal);
end
fprintf('\n');

% Cross-frequency consistency (is the offset the same at all frequencies?)
fprintf('  Per-frequency fs spread (should be small if offset is constant):\n');
fprintf('  Mean of per-freq σ: %.3f Hz\n', mean(std(fs_estimates(good_mask,:), 0, 2)));
fprintf('  Spread of per-freq means: %.3f Hz\n', std(fs_est_avg(good_mask)));
fprintf('\n');

% ── Classification ──
fprintf('  ASSESSMENT: ');
if fs_actual_std < 1.0
    fprintf('FIXED offset (crystal-dominated).\n');
    fprintf('  The ADC clock is stable to ±%.1f Hz across all captures.\n', fs_actual_std);
    fprintf('  Safe to treat as a constant calibration factor.\n');
else
    fprintf('VARIABLE offset (possible jitter or thermal drift).\n');
    fprintf('  Consider re-characterizing if temperature changes significantly.\n');
end
fprintf('\n');

% ── Figure: Sinc envelope validation ──
fig_clk = figure('Name', 'ADC Clock Characterization', ...
    'Position', [120 120 1300 500], 'Color', [0.97 0.96 0.95]);

subplot(1, 2, 1);
hold on; grid on; box on;
plot(freqs/1e3, ratio_LI_FFT, 'ko', 'MarkerSize', 5, 'MarkerFaceColor', 'k', ...
    'DisplayName', 'Measured (lock-in / FFT)');

f_fine = linspace(freqs(1), freqs(end), 1000);
plot(f_fine/1e3, sinc_model(dfs_sinc, f_fine), 'r-', 'LineWidth', 2, ...
    'DisplayName', sprintf('sinc model (Δfs = %+.2f Hz)', dfs_sinc));

xlabel('Frequency (kHz)', 'FontSize', 11);
ylabel('Lock-in / FFT amplitude ratio', 'FontSize', 11);
title('Sinc Attenuation from ADC Clock Offset', 'FontSize', 12, 'FontWeight', 'bold');
legend('Location', 'best', 'FontSize', 9);
ylim([-0.1, 1.1]);

subplot(1, 2, 2);
hold on; grid on; box on;
plot(freqs(good_mask)/1e3, fs_est_avg(good_mask), 'ko-', ...
    'MarkerSize', 4, 'MarkerFaceColor', 'k', 'DisplayName', 'Per-frequency estimate');
yline(fs_actual_mean, 'r-', 'LineWidth', 2, ...
    'Label', sprintf('Mean = %.2f Hz', fs_actual_mean), 'FontSize', 9);
yline(fs_nominal, 'b--', 'LineWidth', 1.5, ...
    'Label', sprintf('Nominal = %d Hz', fs_nominal), 'FontSize', 9);

xlabel('Frequency (kHz)', 'FontSize', 11);
ylabel('Estimated fs (Hz)', 'FontSize', 11);
title('ADC Sample Rate: Per-Frequency Estimates', 'FontSize', 12, 'FontWeight', 'bold');
legend('Location', 'best', 'FontSize', 9);

sgtitle(sprintf('ADC Clock Characterization: Δfs = %+.2f Hz  (%+.1f ppm)', ...
    delta_fs, ppm_offset), 'FontSize', 14, 'FontWeight', 'bold');
%% ═══════════════════════════════════════════════════════════════
% SAVE ALL RESULTS

% Per-channel output (act = driven channel, 0/1) so a ch1 run does not
% overwrite the ch0 fit. active_channel is carried through for provenance.
active_channel = act;
fitted_file = sprintf('sysid_fitted_ch%d.mat', act);
save(fullfile(DATA_DIR, fitted_file), ...
    'freqs', 'n_freqs', 'n_repeats', 'fs', 'input_vpeak', ...
    'amp_lockin_avg', 'amp_lockin_std', 'amp_lockin', ...
    'amp_fft_avg', 'amp_fft_std', 'amp_fft', ...
    'amp_sinefit_avg', 'amp_sinefit_std', 'amp_sinefit', ...
    'phase_lockin', 'phase_sinefit', ...
    'amps_fit', 'amps_fit_std', 'method_label', ...
    'fc_1p', 'gain_1p', 'rmse_1p', 'rss1', ...
    'fc1_2p', 'fc2_2p', 'gain_2p', 'rmse_2p', 'rss2', ...
    'fc_1pf', 'rmse_1pf', 'rss3', ...
    'aicc_1pf', 'aicc_1p', 'aicc_2p', 'best', ...
    'has_notch', 'fc_schematic', 'WIENER_EPS', 'active_channel');

fprintf('Saved: %s\n', fitted_file);
fprintf('\nDone. Inspect waveform gallery (Figure 1) first!\n');
