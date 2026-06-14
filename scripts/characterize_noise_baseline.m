%% characterize_noise_baseline.m — Environmental noise-floor characterization
%  ─────────────────────────────────────────────────────────────────────
%  STANDALONE script that ingests a noise-only capture (sensors recording
%  ambient, no hammer strikes) and produces noise_baseline.mat — a constants
%  file used by daq_burst_quality.m for site-calibrated SNR references
%  and detector thresholds.
%
%  Workflow:
%    1. Load a noise-only capture .mat (slim-save format: raw int32 counts)
%    2. Recover voltages via hardcoded calibration
%    3. Apply Method B Wiener compensation (identical to field script)
%    4. Bandpass-filter to 20–80 kHz (analysis band) and 1–10 kHz (impact band)
%    5. Scan for transients — warn if capture isn't actually quiet
%    6. Compute per-channel robust noise statistics:
%         noise_rms_bp     : broadband (20–80 kHz) noise RMS — SNR reference
%         noise_rms_imp    : impact-band (1–10 kHz) noise RMS — Impact-dB ref
%         STE contour      : median, 1.4826·MAD, 99th percentile
%         LL  contour      : median, 1.4826·MAD, 99th percentile
%    7. Save noise_baseline.mat with timestamp + source filename
%    8. Display diagnostic figure for visual verification
%
%  Use:
%    1. Capture 10 s with start_daq_uae.py — sensors running, do NOT strike
%    2. Point USER_FILE at the resulting captureN.mat (or use LOAD_MODE = 1
%       for "most recent" — fine if nothing else was captured after)
%    3. Run this script; inspect diagnostic figure; confirm clean noise
%    4. noise_baseline.mat is written to DATA_DIR — field script finds it
%       automatically on next run
%
%  Constants (sysid, calibration, compensator) are copied verbatim from
%  daq_burst_quality.m and MUST stay identical byte-for-byte.
% ─────────────────────────────────────────────────────────────────────
clear; clc; close all;

% ═════════════════════════════════════════════════════════════════════
%  USER SETTINGS
% ═════════════════════════════════════════════════════════════════════
DATA_DIR  = 'E:\DAQ Data\Data_files\';

% File loading mode
%   1 = load most-recently-modified .mat in DATA_DIR
%   2 = load user-specified file (USER_FILE below)
LOAD_MODE    = 2;
USER_FILE    = 'noise_baseline_raw.mat';
FILE_PATTERN = 'capture*.mat';

OUTPUT_FILENAME = 'noise_baseline.mat';   % saved to DATA_DIR

% Bandpass filter — MUST MATCH field script
BP_LOW_HZ  = 20000;
BP_HIGH_HZ = 80000;
BP_ORDER   = 4;

% Impact band (low-frequency structural modes) — MUST MATCH field script
IMPACT_BAND_HZ = [1000, 10000];

% STE window size — MUST MATCH field script detector
DET_F_MIN_HZ    = BP_LOW_HZ;
DET_WIN_FACTOR  = 4;

% Transient sanity-check parameters
TRANSIENT_WIN_S    = 0.1;   % 100 ms rolling RMS window
TRANSIENT_RATIO_DB = 20;    % flag if any window exceeds median RMS by > 20 dB

% ═════════════════════════════════════════════════════════════════════
%  CALIBRATION + COMPENSATOR CONSTANTS (verbatim from field script)
%    Calibration gain/offset here is the FALLBACK: per-capture values from
%    the .mat (gain_ch0/offset_ch0/...) are preferred at the conversion
%    site; these apply only when a capture lacks them.
% ═════════════════════════════════════════════════════════════════════
GAIN_CH0   = 0.0000006268;
OFFSET_CH0 = -0.040402;
GAIN_CH1   = 0.0000006355;
OFFSET_CH1 = 0.000751;

EPS_FLOOR = 1e-4;
EPS_WALL  = 50;
F_EDGE    = 135000;
DF_TRANS  = 3000;

SYSID_FREQS = [1000, 5000, 10000, 15000, 20000, 25000, ...
               30000, 33000, 36000, 39000, 42000, 45000, ...
               50000, 53000, 60000, 65000, 70000, 75000, ...
               85000, 90000, 95000, 100000, 110000, 120000];

SYSID_GAIN_CH0 = [0.9997, 0.9924, 0.9691, 0.9321, 0.8835, 0.8255, ...
                  0.7614, 0.7423, 0.7459, 0.7463, 0.7440, 0.7389, ...
                  0.7246, 0.7126, 0.6772, 0.6461, 0.6113, 0.5735, ...
                  0.4925, 0.4501, 0.4242, 0.4264, 0.4180, 0.3960];

SYSID_GAIN_CH1 = [0.9984, 0.9909, 0.9667, 0.9285, 0.8780, 0.8186, ...
                  0.7522, 0.7539, 0.7576, 0.7573, 0.7544, 0.7483, ...
                  0.7321, 0.7191, 0.6805, 0.6469, 0.6094, 0.5688, ...
                  0.4831, 0.4406, 0.4394, 0.4389, 0.4262, 0.4001];

FC_CH0 = 48149;
FC_CH1 = 48674;

% ═════════════════════════════════════════════════════════════════════
%  LOAD DATA
% ═════════════════════════════════════════════════════════════════════
switch LOAD_MODE
    case 1
        files = dir(fullfile(DATA_DIR, FILE_PATTERN));
        if isempty(files)
            error('No files matching %s in %s', FILE_PATTERN, DATA_DIR);
        end
        [~, idx] = max([files.datenum]);
        load_name = files(idx).name;
        filepath  = fullfile(DATA_DIR, load_name);
        fprintf('Loaded latest: %s   (modified %s)\n', load_name, files(idx).date);
    case 2
        load_name = USER_FILE;
        filepath  = fullfile(DATA_DIR, USER_FILE);
        if ~isfile(filepath)
            error('Specified file not found: %s', filepath);
        end
        fprintf('Loaded user-specified: %s\n', USER_FILE);
    otherwise
        error('Invalid LOAD_MODE.');
end

S  = load(filepath);
fs = double(S.sample_rate);

if ~isfield(S, 'ch0_raw') || ~isfield(S, 'ch1_raw')
    error('Capture missing ch0_raw / ch1_raw. Need slim-save format.');
end
ch0_raw = double(S.ch0_raw(:));
ch1_raw = double(S.ch1_raw(:));

N = length(ch0_raw);
t = (0:N-1)' / fs;
duration_s = N / fs;
fprintf('  Samples: %d   Duration: %.2f s   Fs: %.3f kSPS\n', N, duration_s, fs/1e3);

% Calibration → voltages. Prefer the per-capture calibration saved in the
% .mat (start_daq_uae.py writes gain_ch0/offset_ch0/...); fall back to the
% frozen constants for legacy slim-saves. resolve_calib warns on fallback
% or on any mismatch with the frozen defaults, so a stale hardcode cannot
% silently corrupt the voltage scale.
[cal_g0, cal_o0] = resolve_calib(S, 'ch0', GAIN_CH0, OFFSET_CH0);
[cal_g1, cal_o1] = resolve_calib(S, 'ch1', GAIN_CH1, OFFSET_CH1);
ch0_V = ch0_raw * cal_g0 + cal_o0;
ch1_V = ch1_raw * cal_g1 + cal_o1;

% ═════════════════════════════════════════════════════════════════════
%  COMPENSATION (Method B Wiener — hardcoded inline)
% ═════════════════════════════════════════════════════════════════════
fprintf('  Applying Method B compensation...\n');
tic;
ch0_comp = apply_method_b(ch0_V, fs, SYSID_FREQS, SYSID_GAIN_CH0, ...
    FC_CH0, EPS_FLOOR, EPS_WALL, F_EDGE, DF_TRANS);
ch1_comp = apply_method_b(ch1_V, fs, SYSID_FREQS, SYSID_GAIN_CH1, ...
    FC_CH1, EPS_FLOOR, EPS_WALL, F_EDGE, DF_TRANS);
fprintf('  Compensation: %.1f s\n', toc);

% ═════════════════════════════════════════════════════════════════════
%  BANDPASS FILTERS (20–80 kHz for STE/SNR, 1–10 kHz for impact)
% ═════════════════════════════════════════════════════════════════════
[bp_b,  bp_a ] = butter(BP_ORDER, [BP_LOW_HZ, BP_HIGH_HZ] / (fs/2), 'bandpass');
[imp_b, imp_a] = butter(BP_ORDER, IMPACT_BAND_HZ            / (fs/2), 'bandpass');

ch0_bp  = filtfilt(bp_b,  bp_a,  ch0_comp);
ch1_bp  = filtfilt(bp_b,  bp_a,  ch1_comp);
ch0_imp = filtfilt(imp_b, imp_a, ch0_comp);
ch1_imp = filtfilt(imp_b, imp_a, ch1_comp);

% ═════════════════════════════════════════════════════════════════════
%  TRANSIENT SANITY CHECK — is this actually a quiet recording?
% ═════════════════════════════════════════════════════════════════════
% 100 ms rolling RMS of the band-passed signal. If any window's RMS is
% more than TRANSIENT_RATIO_DB above the median rolling-RMS, that's a
% candidate transient — warn the user but don't abort.
win_n = max(1, round(TRANSIENT_WIN_S * fs));

roll_rms_ch0 = sqrt(movmean(ch0_bp.^2, win_n));
roll_rms_ch1 = sqrt(movmean(ch1_bp.^2, win_n));

med_rms_ch0 = median(roll_rms_ch0);
med_rms_ch1 = median(roll_rms_ch1);
max_rms_ch0 = max(roll_rms_ch0);
max_rms_ch1 = max(roll_rms_ch1);

ratio_db_ch0 = 20 * log10(max_rms_ch0 / max(med_rms_ch0, eps));
ratio_db_ch1 = 20 * log10(max_rms_ch1 / max(med_rms_ch1, eps));

transient_flag_ch0 = ratio_db_ch0 > TRANSIENT_RATIO_DB;
transient_flag_ch1 = ratio_db_ch1 > TRANSIENT_RATIO_DB;
transient_flag     = transient_flag_ch0 || transient_flag_ch1;

[~, imax_ch0] = max(roll_rms_ch0);
[~, imax_ch1] = max(roll_rms_ch1);

fprintf('\n  ─── Transient scan (100 ms rolling RMS) ─────────────\n');
fprintf('    Ch0  max/median = %+6.2f dB   (peak at t = %6.3f s)%s\n', ...
    ratio_db_ch0, t(imax_ch0), ternary(transient_flag_ch0, '   ⚠ FLAGGED', ''));
fprintf('    Ch1  max/median = %+6.2f dB   (peak at t = %6.3f s)%s\n', ...
    ratio_db_ch1, t(imax_ch1), ternary(transient_flag_ch1, '   ⚠ FLAGGED', ''));
if transient_flag
    fprintf('\n  ⚠ WARNING — suspected transient(s) in noise capture.\n');
    fprintf('    Inspect the rolling-RMS panel in the diagnostic figure.\n');
    fprintf('    If an accidental tap / EMI spike is present, re-record.\n');
    fprintf('    Statistics below are computed using the whole capture\n');
    fprintf('    (robust estimators — median/MAD — are resistant, but\n');
    fprintf('    not immune, to sustained transients).\n');
end

% ═════════════════════════════════════════════════════════════════════
%  COMPUTE NOISE STATISTICS — per channel
% ═════════════════════════════════════════════════════════════════════
% Broadband and impact-band RMS (used as SNR / Impact-dB references)
noise_rms_bp_ch0  = rms(ch0_bp);
noise_rms_bp_ch1  = rms(ch1_bp);
noise_rms_imp_ch0 = rms(ch0_imp);
noise_rms_imp_ch1 = rms(ch1_imp);

% STE contour — window size MUST match the field detector
win_dur     = DET_WIN_FACTOR / DET_F_MIN_HZ;           % seconds
win_samples = max(1, round(win_dur * fs));
win         = ones(win_samples, 1);

% ── UAE-band (20–80 kHz) STE + LL — used by quality scoring downstream ──
ste_ch0 = sqrt(conv(ch0_bp.^2, win, 'same') / win_samples);
ste_ch1 = sqrt(conv(ch1_bp.^2, win, 'same') / win_samples);

ll_ch0 = conv([0; abs(diff(ch0_bp))], win, 'same');
ll_ch1 = conv([0; abs(diff(ch1_bp))], win, 'same');

% ── Impact-band (1–10 kHz) STE + LL — used by field detector for triggering ──
% Same window size (200 µs) as UAE band — keeps statistics directly comparable
% and matches the field-script detector. Impact-band STE has higher SNR for
% strike detection (1–10 kHz carries ~40% of strike energy vs ~3% in UAE band),
% which lets the field script trigger reliably even when UAE coupling is weak.
ste_ch0_imp = sqrt(conv(ch0_imp.^2, win, 'same') / win_samples);
ste_ch1_imp = sqrt(conv(ch1_imp.^2, win, 'same') / win_samples);

ll_ch0_imp = conv([0; abs(diff(ch0_imp))], win, 'same');
ll_ch1_imp = conv([0; abs(diff(ch1_imp))], win, 'same');

% Robust statistics: median + 1.4826·MAD (σ-equivalent), plus 99th pct
% ── UAE band ──
ste_median_ch0 = median(ste_ch0);
ste_mad_ch0    = 1.4826 * mad1(ste_ch0);
ste_p99_ch0    = p99(ste_ch0);

ste_median_ch1 = median(ste_ch1);
ste_mad_ch1    = 1.4826 * mad1(ste_ch1);
ste_p99_ch1    = p99(ste_ch1);

ll_median_ch0  = median(ll_ch0);
ll_mad_ch0     = 1.4826 * mad1(ll_ch0);
ll_p99_ch0     = p99(ll_ch0);

ll_median_ch1  = median(ll_ch1);
ll_mad_ch1     = 1.4826 * mad1(ll_ch1);
ll_p99_ch1     = p99(ll_ch1);

% ── Impact band ──
ste_median_ch0_imp = median(ste_ch0_imp);
ste_mad_ch0_imp    = 1.4826 * mad1(ste_ch0_imp);
ste_p99_ch0_imp    = p99(ste_ch0_imp);

ste_median_ch1_imp = median(ste_ch1_imp);
ste_mad_ch1_imp    = 1.4826 * mad1(ste_ch1_imp);
ste_p99_ch1_imp    = p99(ste_ch1_imp);

ll_median_ch0_imp  = median(ll_ch0_imp);
ll_mad_ch0_imp     = 1.4826 * mad1(ll_ch0_imp);
ll_p99_ch0_imp     = p99(ll_ch0_imp);

ll_median_ch1_imp  = median(ll_ch1_imp);
ll_mad_ch1_imp     = 1.4826 * mad1(ll_ch1_imp);
ll_p99_ch1_imp     = p99(ll_ch1_imp);

% ═════════════════════════════════════════════════════════════════════
%  CONSOLE SUMMARY
% ═════════════════════════════════════════════════════════════════════
fprintf('\n  ─── Noise statistics ────────────────────────────────\n');
fprintf('                              Ch0           Ch1\n');
fprintf('    RMS broadband (V) :   %.3e   %.3e\n',  noise_rms_bp_ch0,  noise_rms_bp_ch1);
fprintf('    RMS 1–10 kHz  (V) :   %.3e   %.3e\n',  noise_rms_imp_ch0, noise_rms_imp_ch1);
fprintf('    ── UAE band (20–80 kHz) ──\n');
fprintf('    STE median    (V) :   %.3e   %.3e\n',  ste_median_ch0, ste_median_ch1);
fprintf('    STE 1.4826·MAD(V) :   %.3e   %.3e\n',  ste_mad_ch0,    ste_mad_ch1);
fprintf('    STE 99th pct  (V) :   %.3e   %.3e\n',  ste_p99_ch0,    ste_p99_ch1);
fprintf('    LL  median        :   %.3e   %.3e\n',  ll_median_ch0,  ll_median_ch1);
fprintf('    LL  1.4826·MAD    :   %.3e   %.3e\n',  ll_mad_ch0,     ll_mad_ch1);
fprintf('    LL  99th pct      :   %.3e   %.3e\n',  ll_p99_ch0,     ll_p99_ch1);
fprintf('    ── Impact band (1–10 kHz) — used by field detector ──\n');
fprintf('    STE median    (V) :   %.3e   %.3e\n',  ste_median_ch0_imp, ste_median_ch1_imp);
fprintf('    STE 1.4826·MAD(V) :   %.3e   %.3e\n',  ste_mad_ch0_imp,    ste_mad_ch1_imp);
fprintf('    STE 99th pct  (V) :   %.3e   %.3e\n',  ste_p99_ch0_imp,    ste_p99_ch1_imp);
fprintf('    LL  median        :   %.3e   %.3e\n',  ll_median_ch0_imp,  ll_median_ch1_imp);
fprintf('    LL  1.4826·MAD    :   %.3e   %.3e\n',  ll_mad_ch0_imp,     ll_mad_ch1_imp);
fprintf('    LL  99th pct      :   %.3e   %.3e\n',  ll_p99_ch0_imp,     ll_p99_ch1_imp);

% ═════════════════════════════════════════════════════════════════════
%  PACK + SAVE noise_baseline.mat
% ═════════════════════════════════════════════════════════════════════
noise_baseline = struct( ...
    'source_file',       load_name, ...
    'timestamp',         datestr(now, 'yyyy-mm-dd HH:MM:SS'), ...
    'fs',                fs, ...
    'duration_s',        duration_s, ...
    'n_samples',         N, ...
    'bp_band_hz',        [BP_LOW_HZ BP_HIGH_HZ], ...
    'imp_band_hz',       IMPACT_BAND_HZ, ...
    'det_win_samples',   win_samples, ...
    ... % SNR + Impact references
    'ch0_noise_rms_bp',  noise_rms_bp_ch0, ...
    'ch1_noise_rms_bp',  noise_rms_bp_ch1, ...
    'ch0_noise_rms_imp', noise_rms_imp_ch0, ...
    'ch1_noise_rms_imp', noise_rms_imp_ch1, ...
    ... % UAE-band STE statistics
    'ch0_ste_median',    ste_median_ch0, ...
    'ch0_ste_mad',       ste_mad_ch0, ...
    'ch0_ste_p99',       ste_p99_ch0, ...
    'ch1_ste_median',    ste_median_ch1, ...
    'ch1_ste_mad',       ste_mad_ch1, ...
    'ch1_ste_p99',       ste_p99_ch1, ...
    ... % UAE-band LL statistics
    'ch0_ll_median',     ll_median_ch0, ...
    'ch0_ll_mad',        ll_mad_ch0, ...
    'ch0_ll_p99',        ll_p99_ch0, ...
    'ch1_ll_median',     ll_median_ch1, ...
    'ch1_ll_mad',        ll_mad_ch1, ...
    'ch1_ll_p99',        ll_p99_ch1, ...
    ... % Impact-band STE statistics (used by field detector for triggering)
    'ch0_ste_median_imp', ste_median_ch0_imp, ...
    'ch0_ste_mad_imp',    ste_mad_ch0_imp, ...
    'ch0_ste_p99_imp',    ste_p99_ch0_imp, ...
    'ch1_ste_median_imp', ste_median_ch1_imp, ...
    'ch1_ste_mad_imp',    ste_mad_ch1_imp, ...
    'ch1_ste_p99_imp',    ste_p99_ch1_imp, ...
    ... % Impact-band LL statistics
    'ch0_ll_median_imp',  ll_median_ch0_imp, ...
    'ch0_ll_mad_imp',     ll_mad_ch0_imp, ...
    'ch0_ll_p99_imp',     ll_p99_ch0_imp, ...
    'ch1_ll_median_imp',  ll_median_ch1_imp, ...
    'ch1_ll_mad_imp',     ll_mad_ch1_imp, ...
    'ch1_ll_p99_imp',     ll_p99_ch1_imp, ...
    ... % Transient flag
    'transient_flag',    transient_flag, ...
    'ch0_transient_ratio_db', ratio_db_ch0, ...
    'ch1_transient_ratio_db', ratio_db_ch1 ...
);

output_path = fullfile(DATA_DIR, OUTPUT_FILENAME);
save(output_path, 'noise_baseline');
fprintf('\n  ✓ Saved noise baseline → %s\n', output_path);

% ═════════════════════════════════════════════════════════════════════
%  DIAGNOSTIC FIGURE — 3×2 layout
%    Row 1:  Ch0 waveform                | Ch1 waveform
%    Row 2:  Ch0 Welch PSD               | Ch1 Welch PSD
%    Row 3:  Ch0+Ch1 rolling RMS         | STE histograms (Ch0+Ch1)
% ═════════════════════════════════════════════════════════════════════
fig = figure('Color', 'w', 'Name', 'Noise Baseline Characterization');
try
    fig.WindowState = 'maximized';
catch
end

tl = tiledlayout(fig, 3, 2, 'TileSpacing', 'compact', 'Padding', 'compact');
if transient_flag
    title_str = sprintf(['%s   |   Fs=%.1f kSPS   |   %.1fs   |   ', ...
        '\\color{red}⚠ TRANSIENT DETECTED — INSPECT ROLLING RMS'], ...
        load_name, fs/1e3, duration_s);
else
    title_str = sprintf('%s   |   Fs=%.1f kSPS   |   %.1fs   |   \\color[rgb]{0,0.5,0}clean', ...
        load_name, fs/1e3, duration_s);
end
title(tl, title_str, 'FontWeight', 'bold', 'Interpreter', 'tex');

% ── Row 1: waveforms ──
ax = nexttile(tl);
plot(ax, t, ch0_bp, 'Color', [0.78 0.13 0.13], 'LineWidth', 0.5);
grid(ax, 'on'); ax.GridAlpha = 0.25;
ylabel(ax, 'Ch0  (V)');
title(ax, 'Ch0 — Compensated, 20–80 kHz band-passed', 'FontWeight', 'bold');
ylim_wave = [-1 1] * max(max(abs(ch0_bp)), max(abs(ch1_bp))) * 1.1;
ylim(ax, ylim_wave);

ax = nexttile(tl);
plot(ax, t, ch1_bp, 'Color', [0.13 0.45 0.78], 'LineWidth', 0.5);
grid(ax, 'on'); ax.GridAlpha = 0.25;
ylabel(ax, 'Ch1  (V)');
title(ax, 'Ch1 — Compensated, 20–80 kHz band-passed', 'FontWeight', 'bold');
ylim(ax, ylim_wave);

% ── Row 2: Welch PSDs (full-band, log-x) ──
nfft = 2^nextpow2(min(N, 131072));
[pxx0, f_psd] = pwelch(ch0_comp, hann(nfft), nfft/2, nfft, fs, 'power');
[pxx1, ~]     = pwelch(ch1_comp, hann(nfft), nfft/2, nfft, fs, 'power');
db0 = 10*log10(pxx0 + eps);
db1 = 10*log10(pxx1 + eps);

ax = nexttile(tl);
semilogx(ax, f_psd/1e3, db0, 'Color', [0.78 0.13 0.13], 'LineWidth', 0.7); hold(ax, 'on');
add_band_patches(ax, IMPACT_BAND_HZ, [BP_LOW_HZ BP_HIGH_HZ]);
grid(ax, 'on'); ax.GridAlpha = 0.25; set(ax, 'XMinorGrid', 'on');
xlim(ax, [0.1, fs/2e3]);
xlabel(ax, 'Frequency  (kHz)'); ylabel(ax, 'Ch0  (dBV^2)');
title(ax, 'Ch0 — Welch PSD (compensated)', 'FontWeight', 'bold');

ax = nexttile(tl);
semilogx(ax, f_psd/1e3, db1, 'Color', [0.13 0.45 0.78], 'LineWidth', 0.7); hold(ax, 'on');
add_band_patches(ax, IMPACT_BAND_HZ, [BP_LOW_HZ BP_HIGH_HZ]);
grid(ax, 'on'); ax.GridAlpha = 0.25; set(ax, 'XMinorGrid', 'on');
xlim(ax, [0.1, fs/2e3]);
xlabel(ax, 'Frequency  (kHz)'); ylabel(ax, 'Ch1  (dBV^2)');
title(ax, 'Ch1 — Welch PSD (compensated)', 'FontWeight', 'bold');

% ── Row 3a: Rolling RMS (transient check) ──
ax = nexttile(tl);
plot(ax, t, 20*log10(roll_rms_ch0 / max(med_rms_ch0, eps)), ...
    'Color', [0.78 0.13 0.13], 'LineWidth', 0.8, 'DisplayName', 'Ch0'); hold(ax, 'on');
plot(ax, t, 20*log10(roll_rms_ch1 / max(med_rms_ch1, eps)), ...
    'Color', [0.13 0.45 0.78], 'LineWidth', 0.8, 'DisplayName', 'Ch1');
yline(ax, TRANSIENT_RATIO_DB, '--k', ...
    sprintf('+%d dB flag', TRANSIENT_RATIO_DB), ...
    'LabelHorizontalAlignment', 'left', 'HandleVisibility', 'off');
grid(ax, 'on'); ax.GridAlpha = 0.25;
xlabel(ax, 'Time  (s)');
ylabel(ax, 'Rolling RMS  (dB re median)');
title(ax, sprintf('Rolling RMS (%.0f ms window) — transient check', ...
    TRANSIENT_WIN_S*1e3), 'FontWeight', 'bold');
legend(ax, 'Location', 'best', 'Box', 'off');

% ── Row 3b: STE histograms (log x) ──
ax = nexttile(tl);
edges = logspace(log10(max(min([ste_ch0; ste_ch1]), eps)), ...
                 log10(max(max(ste_ch0), max(ste_ch1))*1.1), 80);
histogram(ax, ste_ch0, edges, 'FaceColor', [0.78 0.13 0.13], 'FaceAlpha', 0.5, ...
    'EdgeColor', 'none', 'DisplayName', 'Ch0'); hold(ax, 'on');
histogram(ax, ste_ch1, edges, 'FaceColor', [0.13 0.45 0.78], 'FaceAlpha', 0.5, ...
    'EdgeColor', 'none', 'DisplayName', 'Ch1');
set(ax, 'XScale', 'log');
xline(ax, ste_median_ch0, ':', 'Color', [0.78 0.13 0.13], 'LineWidth', 1.2, 'HandleVisibility','off');
xline(ax, ste_p99_ch0,    '--','Color', [0.78 0.13 0.13], 'LineWidth', 1.2, 'HandleVisibility','off');
xline(ax, ste_median_ch1, ':', 'Color', [0.13 0.45 0.78], 'LineWidth', 1.2, 'HandleVisibility','off');
xline(ax, ste_p99_ch1,    '--','Color', [0.13 0.45 0.78], 'LineWidth', 1.2, 'HandleVisibility','off');
grid(ax, 'on'); ax.GridAlpha = 0.25;
xlabel(ax, 'STE  (V)'); ylabel(ax, 'count');
title(ax, 'STE distribution (dotted = median, dashed = 99th pctile)', ...
    'FontWeight', 'bold');
legend(ax, 'Location', 'northeast', 'Box', 'off');

fprintf('\n  Diagnostic figure drawn. Inspect, then close to finish.\n');

% ═════════════════════════════════════════════════════════════════════
%  HELPER FUNCTIONS
% ═════════════════════════════════════════════════════════════════════

function add_band_patches(ax, imp_band, bp_band)
% Shade the impact (1–10 kHz) and analysis (20–80 kHz) bands on a PSD axis.
    yl = ylim(ax);
    if all(isfinite(yl)) && yl(2) > yl(1)
        patch(ax, [imp_band(1) imp_band(2) imp_band(2) imp_band(1)]/1e3, ...
              [yl(1) yl(1) yl(2) yl(2)], [0.55 0.80 0.55], ...
              'FaceAlpha', 0.12, 'EdgeColor', 'none', 'HandleVisibility', 'off');
        patch(ax, [bp_band(1)  bp_band(2)  bp_band(2)  bp_band(1) ]/1e3, ...
              [yl(1) yl(1) yl(2) yl(2)], [0.55 0.55 0.80], ...
              'FaceAlpha', 0.12, 'EdgeColor', 'none', 'HandleVisibility', 'off');
    end
end

function out = ternary(cond, a, b)
    if cond, out = a; else, out = b; end
end

function m = mad1(x)
% Median Absolute Deviation about the median — base-MATLAB implementation
% equivalent to mad(x, 1) from the Statistics & Machine Learning Toolbox.
% Stats Toolbox is not assumed in this script.
    x = x(:);
    m = median(abs(x - median(x)));
end

function q = p99(x)
% 99th percentile via linear interpolation on sorted data — base-MATLAB
% equivalent to quantile(x, 0.99). Stats Toolbox not assumed.
    x = sort(x(:));
    n = numel(x);
    if n == 0,  q = NaN;     return; end
    if n == 1,  q = x(1);    return; end
    pos = 0.99 * (n - 1) + 1;       % 1-indexed position
    lo  = floor(pos);
    hi  = min(lo + 1, n);
    w   = pos - lo;
    q   = (1 - w) * x(lo) + w * x(hi);
end

function y_comp = apply_method_b(y_in, fs, sysid_freqs, sysid_gain, fc_1p, ...
                                  eps_floor, eps_wall, f_edge, df_trans)
% Method B Wiener compensation — EXACT validated implementation.
% Identical to Python's apply_compensation in start_daq_uae.py and the
% MATLAB analysis script daq_burst_quality.m.
    y_dc = mean(y_in);
    y    = y_in - y_dc;

    N    = length(y);
    f    = (0:floor(N/2))' * fs / N;
    n_pos = length(f);

    mag = ones(n_pos, 1);
    f_min = sysid_freqs(1);
    f_max = sysid_freqs(end);
    pchip_fn = griddedInterpolant(sysid_freqs(:), log(sysid_gain(:)), 'pchip');
    in_range = (f >= f_min) & (f <= f_max);
    mag(in_range) = exp(pchip_fn(f(in_range)));
    above = f > f_max;
    if any(above)
        scale = sqrt(1 + (f_max/fc_1p)^2);
        mag(above) = sysid_gain(end) * scale ./ sqrt(1 + (f(above)/fc_1p).^2);
    end
    mag(1) = 1.0;
    mag = max(mag, 1e-6);

    log_mag_full = [log(mag); flipud(log(mag(2:end-1)))];
    ceps = real(ifft(log_mag_full));
    win_c = zeros(N, 1);
    win_c(1)       = 1;
    win_c(2:N/2)   = 2;
    win_c(N/2+1)   = 1;
    min_ph = exp(fft(ceps .* win_c));
    phi    = angle(min_ph(1:n_pos));

    H_afe   = mag .* exp(1j * phi);
    sigmoid = 0.5 * (1 + tanh((f - f_edge) / df_trans));
    eps_f   = eps_floor + eps_wall * sigmoid;
    G       = conj(H_afe) ./ (abs(H_afe).^2 + eps_f);

    G_full = [G; conj(flipud(G(2:end-1)))];
    Y      = fft(y);
    Y_comp = Y .* G_full;
    y_comp = real(ifft(Y_comp));
    y_comp = y_comp + y_dc;
end
function [g, o] = resolve_calib(S, ch, g_default, o_default)
% Resolve per-channel ADC calibration (volts = raw*g + o). Prefers the
% values stored in the capture .mat (gain_<ch>/offset_<ch>) over the frozen
% script defaults; warns on fallback or mismatch so a stale hardcode cannot
% silently corrupt the voltage scale.
    gfield = ['gain_'   ch];
    ofield = ['offset_' ch];
    if isfield(S, gfield) && isfield(S, ofield)
        g = double(S.(gfield));
        o = double(S.(ofield));
        if abs(g - g_default) > 1e-12 || abs(o - o_default) > 1e-9
            fprintf(['  ⚠ %s calibration in capture (g=%.6g, o=%+.6g) ' ...
                'differs from frozen defaults (g=%.6g, o=%+.6g); ' ...
                'using capture values.\n'], ch, g, o, g_default, o_default);
        end
    else
        g = g_default;  o = o_default;
        fprintf(['  ⚠ Capture has no %s calibration; using frozen ' ...
            'defaults (g=%.6g, o=%+.6g).\n'], ch, g_default, o_default);
    end
end
