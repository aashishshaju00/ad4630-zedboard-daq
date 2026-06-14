%% daq_burst_quality.m — Field hammer-strike quality assessment
%  ─────────────────────────────────────────────────────────────────────
%  STANDALONE field script — single file, no external dependencies beyond
%  built-in MATLAB toolboxes (Signal Processing Toolbox).
%
%  Workflow:
%    1. Load latest (or user-specified) capture .mat
%    2. Recover voltages from raw ADC counts via hardcoded calibration
%    3. Apply Method B Wiener compensation (hardcoded sysid arrays)
%    4. Bandpass-filter to 20–80 kHz (UA emission band)
%    5. Load noise baseline (from characterize_noise_baseline.m) if present,
%       else compute stats from first 1 s of capture (legacy fallback)
%    6. Detect bursts independently per channel (STE + LL dual-contour,
%       MAD-based robust thresholds, absolute peak-amplitude floor)
%    7. Check drift of capture noise vs baseline (warn if > ±6 dB)
%    8. Compute per-burst quality metrics: SNR, decay R², PSD correlation
%    9. Check raw ADC for clipping/saturation
%   10. Display four figures: verdict dashboard, time-domain, zoomed starts, raw time-domain
%   11. Prompt user: keep / keep-with-note / skip
%   12. Append decision to field_log.csv
%
%  Quality metrics per burst:
%    SNR (dB)        : 20*log10(burst_RMS / noise_RMS)
%    Decay R²        : weighted log-domain exp fit on peak → peak−25 dB
%    τ (ms)          : ring-down time constant from the decay fit
%    PSD correlation : Pearson corr (in dB) vs the most representative
%                      burst's PSD (template = highest mean pairwise PSD
%                      correlation). Template-burst itself gets PSDcorr = NaN.
%    Impact (dB)     : 20*log10(burst_RMS_1-10kHz / noise_RMS_1-10kHz)
%
%  Hard gates (Tier 2 — applied before GOOD/MARG/BAD classification):
%    impact_pass    : Imp dB ≥ 15 (real structural-mode excitation)
%    τ in [2, 50] ms: physically plausible ring-down
%    Either gate failing → BAD regardless of other metrics.
%  Verdict thresholds:
%    GOOD     : SNR ≥ 35 AND R² ≥ 0.95 AND PSDcorr ≥ 0.80
%    MARGINAL : (≥25, ≥0.85, ≥0.60) AND not GOOD
%    BAD      : anything below MARGINAL  (or any hard gate failure)
%    SATURATED: ANY raw ADC sample in burst window ≥ 0.95 × 2^23 → red banner
%
%  Compensator: EXACT validated Method B implementation (frozen).
%
%  Usage:
%    1. (Once per site/session) Run characterize_noise_baseline.m on a
%       noise-only capture to produce noise_baseline.mat in DATA_DIR
%    2. Set LOAD_MODE / USER_FILE at top, run.
%    3. If noise_baseline.mat absent, legacy first-1s stats are used.
% ─────────────────────────────────────────────────────────────────────
clear; clc; close all;
% ═════════════════════════════════════════════════════════════════════
%  │  RUN MODE                                                      
% ═════════════════════════════════════════════════════════════════════
% BATCH_MODE = false → process ONE file (USER_FILE), full diagnostic
%                      dashboard, manual KEEP/SKIP/KEEP_NOTE prompt.
%                      Use this for tuning a problematic capture.
% BATCH_MODE = true  → loop through all captures listed in INPUT_FILES,
%                      skip any already in the manifest, prompt per-file,
%                      save burst clips to BURST_OUT_DIR on KEEP/KEEP_NOTE.
%                      Use this for production extraction.
BATCH_MODE       = true;
FORCE_REPROCESS  = false;   % batch mode only: if true, ignore manifest
                            % and reprocess every file from scratch.


% Per-capture tuning workflow: tune globals on a problem capture in
% single-file mode, then save the burst file + manifest entry without
% having to switch to batch mode. The manifest update upserts (replaces
% existing row by basename if present, else appends) so re-running a
% capture cleanly overwrites the prior bad burst file and manifest entry.
BURST_SAVE_IN_SINGLE_MODE = true;

% Diagnostic verbosity for refine_burst_hilbert. When true, prints a per-
% burst trace of impact-window bounds, envelope peak location/amplitude,
% peak_thresh comparison, fallback decision, walk-back/forward outcomes,
% and final refined window. Use for debugging UAE refinement issues
% (e.g. burst-merging in Specimen_4_P5). Off by default — verbose output
% would dominate console during batch runs.
UAE_REFINE_VERBOSE = true;
% ─── Batch mode (BATCH_MODE = true) ─────────────────────────────────────
% Input list is GENERATED programmatically below from these knobs.
% Edit SPECIMEN_IDS to a subset (e.g. [3 5]) for partial runs.
SPECIMEN_IDS        = 1:11;
MEASUREMENT_POINTS        = {'P1', 'P2', 'P3', 'P4', 'P5', 'P6'};
%   P1–P6 are user-defined measurement points on the test article.
% ════════════════════════════════════════════════════════════════════
%  │  PATHS                                                         
% ═════════════════════════════════════════════════════════════════════

% =========================================================================
%  DATASET SELECTOR — switch between measurement campaigns
% =========================================================================
%   'SET_A' = first measurement campaign, specimens 1–11
%   'SET_B' = second measurement campaign, specimens 12–22
DATASET = 'SET_B';     % <<< change this to 'SET_A' or 'SET_B'

switch DATASET
    case 'SET_A'
        DATA_DIR      = 'E:\DAQ Data\Data_files\';
        BURST_OUT_DIR = 'E:\DAQ Data\Burst_files\';
        SPECIMEN_IDS     = 1:11;
        USER_FILE     = 'Specimen_5_P1.mat';   % only used in single-file mode
    case 'SET_B'
        DATA_DIR      = 'E:\DAQ Data\Data_files_B\';
        BURST_OUT_DIR = 'E:\DAQ Data\Burst_files_B\';
        SPECIMEN_IDS     = 12:22;
        USER_FILE     = 'Specimen_12_P1.mat';
    otherwise
        error('Unknown DATASET: %s. Use ''SET_A'' or ''SET_B''.', DATASET);
end
fprintf('DATASET = %s  (DATA_DIR=%s, BURST_OUT_DIR=%s)\n', ...
    DATASET, DATA_DIR, BURST_OUT_DIR);

MANIFEST_FILE    = 'processed.mat';                  % lives in BURST_OUT_DIR
SCRIPT_VERSION   = 'V3';                             % stamped in manifest + burst files
% (Single-file mode legacy auto-load — find most-recent .mat in DATA_DIR.
%  Set LOAD_MODE = 1 in single-file mode to use this; ignored in batch mode.)
LOAD_MODE        = 2;
FILE_PATTERN     = 'Specimen_*.mat';

% Noise baseline file (produced by characterize_noise_baseline.m).
% Lives in DATA_DIR. If absent, detector falls back to first-NOISE_BASELINE_S
% of each capture for noise stats (legacy Tier-1 behavior).
NOISE_BASELINE_FILE = 'noise_baseline.mat';

% Single-file session log (CSV, append-only). Single-file mode only;
% batch mode uses the manifest table instead.
LOG_FILENAME     = 'field_log.csv';

% ═════════════════════════════════════════════════════════════════════
%  ┌─────────────────────────────────────────────────────────────────┐
%  │  TUNING PARAMETERS                                              │
%  │  All tuning knobs in one place. Inline comments at usage sites  │
%  │  point back here; do NOT modify values inline below.            │
%  └─────────────────────────────────────────────────────────────────┘
% ═════════════════════════════════════════════════════════════════════

% ── Field protocol ──────────────────────────────────────────────────────
N_STRIKES_EXPECTED = 3;     % Number of hammer strikes expected per capture
NOISE_BASELINE_S   = 0.25;   % first N seconds of capture used as noise ref
                            %   (only when noise_baseline.mat absent)

% ── UAE bandpass (analysis band) ────────────────────────────────────────
BP_LOW_HZ  = 20000;         % UAE band low edge
BP_HIGH_HZ = 80000;         % UAE band high edge
BP_ORDER   = 4;             % Butterworth order (zero-phase via filtfilt)

% ── STAGE 1 — Impact-band burst detection (state machine) ───────────────
% Detection runs on 1–10 kHz IMPACT band. Single-sample OFF termination
% prevents strike-merging across long inter-strike gaps.
DET_F_MIN_HZ     = BP_LOW_HZ;  % drives STE/LL window sizing (200 µs window)
DET_WIN_FACTOR   = 4;          % STE/LL window width = WIN_FACTOR / F_MIN
DET_NOISE_DUR_S  = NOISE_BASELINE_S;
DET_ON_THRESH    = 12;         % ON  multiplier on σ_eq (median + N·1.4826·MAD)
DET_OFF_THRESH   = 6;          % OFF multiplier on σ_eq
DET_LOCKOUT_S    = 0.2;        % min seconds between bursts (field protocol: 1–2 s)
DET_PEAK_FLOOR_MULT = 100;     % min burst peak STE = N × noise median
                               %   ladder-down 100→75→50 if a specimen misses

% ── STAGE 2 — Window extension (post-detection, hysteresis + cap) ───────
% Extends each detected burst's end forward with hysteresis so windows
% capture the full impact-band ringdown. Capped at next-strike-start - margin.
DET_OFF_HYST_MS         = 50;   % ms below OFF required to terminate stage-2
DET_NEXT_STRIKE_MARGIN_S = 0.10; % min gap between burst-N end & burst-(N+1) start

% ── STAGE 2.5 — Strongest-N cap (post-stage-2, pre-refinement) ──────────
% When set to a finite number, after stage-2 produces N detected windows,
% sort by peak STE descending and keep only the top MAX_BURSTS_CAP_GLOBAL.
% Use this when raising DET_PEAK_FLOOR_MULT alone can't separate ghosts
% from weak-but-real strikes (Specimen_3_P2 is the canonical case — ghost
% peaks overlap the weakest real strike's peak, so no scalar threshold
% can split them).
%
% Assumes "exactly N strikes per capture" — true for the field protocol.
% Risk: if a real strike is genuinely missed AND a ghost is detected, the
% cap will keep the ghost. So pair this with sane DET_PEAK_FLOOR_MULT and
% review the dashboard for each capture this is enabled on.
%
% Default = inf (no cap). Set to 3 for problem captures.
MAX_BURSTS_CAP_GLOBAL = 3;

% ── STAGE 3 — UAE refinement (Hilbert envelope, finds defect window) ────
% After stage-2 produces wide impact-band windows, walks the Hilbert
% envelope of the UAE bandpass to find the actual UAE-band onset/offset
% (typically 100–700 ms inside the impact window).
UAE_REFINE_LPF_HZ       = 200;   % envelope LPF cutoff (Hz)
UAE_REFINE_K_OFF        = 3;     % off-thresh additive: env_med + K_OFF·mad
UAE_REFINE_K_REL        = 1.3;   % off-thresh multiplicative: K_REL·env_med
                                 %   1.3 ≈ +2.3 dB above noise (was 2.0 = 6 dB,
                                 %   shortened Ch0 windows; lowered post-P1 tuning)
UAE_REFINE_K_PEAK       = 6;     % weak-burst fallback if env peak below this
UAE_REFINE_K_PEAK_FRAC  = 0.03;  % per-burst floor: terminate at K·peak (-30 dB)
UAE_REFINE_HYST_MS      = 15;    % consecutive ms below off-thresh to terminate
                                 %   (was 5; raised post-P1 tuning so Ch0
                                 %   late-decay dips don't trigger early stop)
UAE_REFINE_NOISE_S      = 0.5;   % first N seconds used for noise estimate
UAE_REFINE_FALLBACK_S   = 0.20;  % fallback window width when peak too weak
% Bound the envelope-peak search to the first N seconds AFTER the impact-band
% window start. Stage-2 can extend a burst's impact window across a long
% inter-strike gap (capped at next_strike_start − margin), and inside that
% wide window the global env max can land near the FAR end (e.g. filtfilt
% bidirectional smoothing of the next strike's huge UAE peak bleeding back).
% Real UAE responses peak within ~ms of impact onset, so 300 ms is generous.
% Bug discovered 2026-05: Specimen_4_P5 Ch1 burst 2 — strike-2 UAE response
% (~5 mV peak at t=7.0s) was masked by strike-3 backwards-bleed (~9 mV at
% t=11.62s) because burst 2's impact window was [6.899s, 11.716s].
UAE_REFINE_PEAK_SEARCH_S = 0.30; % seconds after impact window start to
                                 %   search for the envelope peak. Walk-back
                                 %   /walk-forward still operate over the
                                 %   full impact window after peak is found.

% ── STAGE 4 — Head/tail extension (cosmetic, post-refinement) ───────────
DET_HEAD_EXT_S  = 0.001;       % 1 ms pre-onset buffer
DET_TAIL_EXT_S  = 0.020;       % 20 ms post-end buffer

% ── Decay fit (per-burst on UAE-band envelope) ──────────────────────────
DECAY_DYNAMIC_RANGE_DB = 25;   % fit from peak down to peak−25 dB

% ── Welch PSD (for inter-strike PSD correlation) ────────────────────────
WELCH_TARGET_AVG = 30;         % aim for ~30 averages per burst
PSD_BAND_HZ      = [BP_LOW_HZ, BP_HIGH_HZ];

% ── Impact-strength gate (1–10 kHz band structural-mode energy) ─────────
IMPACT_BAND_HZ           = [1000, 10000];
IMPACT_MIN_DB_OVER_NOISE = 15;   % min impact-band SNR for burst to count

% ── Quality thresholds (Good / Marginal cutoffs) ────────────────────────
SNR_GOOD_DB    = 35; SNR_MARG_DB    = 25;
R2_GOOD        = 0.95; R2_MARG      = 0.85;
PSDCORR_GOOD   = 0.80; PSDCORR_MARG = 0.60;
TAU_MIN_MS     = 2;     % below this is too short to be a real ring-down
TAU_MAX_MS     = 50;    % above this is physically implausible

% ── Saturation (raw ADC counts; AD4630-24 24-bit signed → ±2^23) ────────
SAT_FRACTION = 0.95;
SAT_LIMIT    = SAT_FRACTION * 2^23;     % = 7,969,546

% ── Drift check (capture STE median vs baseline) ────────────────────────
DRIFT_WARN_DB    = 6;          % warn if drift > this many dB

% ═════════════════════════════════════════════════════════════════════
%    END OF USER-EDITABLE PARAMETERS                               
%    Constants below (calibration, compensator, sysid) are FROZEN. 
% ═════════════════════════════════════════════════════════════════════

% ═════════════════════════════════════════════════════════════════════
%  CALIBRATION + COMPENSATOR CONSTANTS
%    Compensator/sysid constants are FROZEN (used as-is below).
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
%  │  BATCH ORCHESTRATION                                            
%  │  Builds the file list, loads/creates the manifest, filters out  
%  │  already-processed files (unless FORCE_REPROCESS), and opens    
%  │  the per-file loop. Single-file mode collapses to a 1-element   
%  │  list for code uniformity.                                      
% ═════════════════════════════════════════════════════════════════════

% Build the input file list ----------------------------------------------
if BATCH_MODE
    % Programmatically generate {Specimen_W_POINT.mat} for every (specimen, measurement point).
    INPUT_FILES = cell(0, 1);
    for w = SPECIMEN_IDS
        for p = 1:length(MEASUREMENT_POINTS)
            INPUT_FILES{end+1, 1} = sprintf('Specimen_%d_%s.mat', w, MEASUREMENT_POINTS{p}); %#ok<SAGROW>
        end
    end
    fprintf('═══════════════════════════════════════════════════════════════\n');
    fprintf('  BATCH MODE   |   %d specimens × %d points = %d captures\n', ...
        length(SPECIMEN_IDS), length(MEASUREMENT_POINTS), length(INPUT_FILES));
    fprintf('═══════════════════════════════════════════════════════════════\n');
else
    % Single-file mode: legacy LOAD_MODE switch (1 = latest, 2 = USER_FILE).
    if LOAD_MODE == 1
        flist = dir(fullfile(DATA_DIR, FILE_PATTERN));
        if isempty(flist)
            error('No files matching %s in %s', FILE_PATTERN, DATA_DIR);
        end
        [~, latest_idx] = max([flist.datenum]);
        INPUT_FILES = {flist(latest_idx).name};
    elseif LOAD_MODE == 2
        INPUT_FILES = {USER_FILE};
    else
        error('Invalid LOAD_MODE.');
    end
    fprintf('SINGLE-FILE MODE: %s\n', INPUT_FILES{1});
end

% Ensure the burst-output directory exists (batch or single-with-save) ---
if (BATCH_MODE || BURST_SAVE_IN_SINGLE_MODE) && ~isfolder(BURST_OUT_DIR)
    fprintf('  Creating burst output directory: %s\n', BURST_OUT_DIR);
    mkdir(BURST_OUT_DIR);
end

% Load or initialize the manifest table (batch or single-with-save) ------
manifest_path = fullfile(BURST_OUT_DIR, MANIFEST_FILE);
if BATCH_MODE || BURST_SAVE_IN_SINGLE_MODE
    if isfile(manifest_path)
        Mload = load(manifest_path);
        if isfield(Mload, 'manifest')
            manifest = Mload.manifest;
            fprintf('  Loaded manifest: %d entries\n', height(manifest));
        else
            warning('Manifest file present but no ''manifest'' variable; starting fresh.');
            manifest = make_empty_manifest();
        end
        clear Mload
    else
        manifest = make_empty_manifest();
        fprintf('  No manifest found; starting fresh.\n');
    end
else
    manifest = make_empty_manifest();   % unused in single-file/no-save mode
end

% Filter input list against manifest -------------------------------------
if BATCH_MODE && ~FORCE_REPROCESS && ~isempty(manifest)
    already_done = manifest.basename;
    keep_mask = true(length(INPUT_FILES), 1);
    for i = 1:length(INPUT_FILES)
        [~, base_i, ~] = fileparts(INPUT_FILES{i});
        if any(strcmp(already_done, base_i))
            keep_mask(i) = false;
        end
    end
    n_skipped = sum(~keep_mask);
    if n_skipped > 0
        fprintf('  Skipping %d already-processed captures (FORCE_REPROCESS=false).\n', n_skipped);
    end
    INPUT_FILES = INPUT_FILES(keep_mask);
elseif BATCH_MODE && FORCE_REPROCESS
    fprintf('  FORCE_REPROCESS=true — manifest ignored, processing ALL %d captures.\n', ...
        length(INPUT_FILES));
end

if isempty(INPUT_FILES)
    fprintf('\n  Nothing to do — all captures already in manifest.\n');
    fprintf('  (Set FORCE_REPROCESS = true to redo everything.)\n');
    return;
end

n_total_to_process = length(INPUT_FILES);

% ═════════════════════════════════════════════════════════════════════
%  PER-FILE LOOP (collapses to a single iteration in single-file mode)
% ═════════════════════════════════════════════════════════════════════
for batch_idx = 1:n_total_to_process

% Close any figures from the prior iteration (clean redraw per capture) --
if BATCH_MODE
    close all;
end

load_name = INPUT_FILES{batch_idx};
filepath  = fullfile(DATA_DIR, load_name);
[~, basename_no_ext, ~] = fileparts(load_name);

if BATCH_MODE
    fprintf('\n');
    fprintf('═══════════════════════════════════════════════════════════════\n');
    fprintf('  [%d / %d]   %s\n', batch_idx, n_total_to_process, load_name);
    fprintf('═══════════════════════════════════════════════════════════════\n');
end

if ~isfile(filepath)
    fprintf('  ⚠ FILE NOT FOUND: %s — skipping.\n', filepath);
    continue;
end
if ~BATCH_MODE
    fprintf('Loaded user-specified: %s\n', load_name);
end

% ═════════════════════════════════════════════════════════════════════
%  LOAD DATA
% ═════════════════════════════════════════════════════════════════════
S  = load(filepath);
fs = double(S.sample_rate);

% Raw counts (int32). Slim-save means raw is the only thing guaranteed present.
if ~isfield(S, 'ch0_raw') || ~isfield(S, 'ch1_raw')
    fprintf('  ⚠ Capture missing ch0_raw / ch1_raw. Skipping.\n');
    continue;
end
ch0_raw = double(S.ch0_raw(:));
ch1_raw = double(S.ch1_raw(:));

N = length(ch0_raw);
t = (0:N-1)' / fs;
fprintf('  Samples: %d   Duration: %.2f s   Fs: %.3f kSPS\n', N, N/fs, fs/1e3);

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
%  LOAD NOISE BASELINE (if available)
% ═════════════════════════════════════════════════════════════════════
baseline_path   = fullfile(DATA_DIR, NOISE_BASELINE_FILE);
baseline_loaded = false;
nb              = struct();   % placeholder; populated on successful load
if isfile(baseline_path)
    try
        Bfile = load(baseline_path, 'noise_baseline');
        nb    = Bfile.noise_baseline;
        % Sanity: sample rate must match within 0.1 %
        if abs(nb.fs - fs) / fs > 1e-3
            fprintf('  ⚠ Baseline fs mismatch (baseline %.3f kSPS vs capture %.3f kSPS) — ignoring baseline\n', ...
                nb.fs/1e3, fs/1e3);
        else
            baseline_loaded = true;
            fprintf('  Noise baseline loaded: %s\n', NOISE_BASELINE_FILE);
            fprintf('    Source: %s   (captured %s)\n', nb.source_file, nb.timestamp);
            if nb.transient_flag
                fprintf('    ⚠ Baseline was flagged for transients when characterized — consider re-baselining\n');
            end
        end
    catch ME
        fprintf('  ⚠ Failed to load baseline (%s) — falling back to first-%.1fs\n', ...
            ME.message, NOISE_BASELINE_S);
    end
else
    fprintf('  No noise baseline found at %s\n', baseline_path);
    fprintf('    Falling back to first-%.1fs-of-capture noise stats (legacy behavior)\n', ...
        NOISE_BASELINE_S);
end

% ═════════════════════════════════════════════════════════════════════
%  ADC SATURATION CHECK (on raw counts, BEFORE any processing)
% ═════════════════════════════════════════════════════════════════════
sat_mask_ch0 = abs(ch0_raw) >= SAT_LIMIT;
sat_mask_ch1 = abs(ch1_raw) >= SAT_LIMIT;
fprintf('  Saturation check (>%.0f%% of 2^23): Ch0 %d samples, Ch1 %d samples\n', ...
    SAT_FRACTION*100, nnz(sat_mask_ch0), nnz(sat_mask_ch1));

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
%  BANDPASS 20–80 kHz (4th-order Butterworth, zero-phase) — UAE band
%  used for all quality scoring (SNR, decay, PSDcorr).
% ═════════════════════════════════════════════════════════════════════
[bp_b, bp_a] = butter(BP_ORDER, [BP_LOW_HZ, BP_HIGH_HZ] / (fs/2), 'bandpass');
ch0_bp = filtfilt(bp_b, bp_a, ch0_comp);
ch1_bp = filtfilt(bp_b, bp_a, ch1_comp);

% ═════════════════════════════════════════════════════════════════════
%  BANDPASS 1–10 kHz — IMPACT band, used for burst DETECTION (triggering).
%  Moved up from later in the script (formerly computed alongside the
%  per-burst impact_pass gate) so it's available when the detector runs.
% ═════════════════════════════════════════════════════════════════════
[imp_b, imp_a] = butter(BP_ORDER, IMPACT_BAND_HZ / (fs/2), 'bandpass');
ch0_imp = filtfilt(imp_b, imp_a, ch0_comp);
ch1_imp = filtfilt(imp_b, imp_a, ch1_comp);

% ═════════════════════════════════════════════════════════════════════
%  BURST DETECTION — independent per channel, on IMPACT band
% ═════════════════════════════════════════════════════════════════════
% Build per-channel baseline stat sub-structs for the detector.
% Pull the IMPACT-band stats produced by characterize_noise_baseline.m.
% Empty struct → detector falls back to first noise_dur_s of the contour.
if baseline_loaded && isfield(nb, 'ch0_ste_median_imp')
    baseline_ch0 = struct('ste_median', nb.ch0_ste_median_imp, 'ste_mad', nb.ch0_ste_mad_imp, ...
                          'll_median',  nb.ch0_ll_median_imp,  'll_mad',  nb.ch0_ll_mad_imp);
    baseline_ch1 = struct('ste_median', nb.ch1_ste_median_imp, 'ste_mad', nb.ch1_ste_mad_imp, ...
                          'll_median',  nb.ch1_ll_median_imp,  'll_mad',  nb.ch1_ll_mad_imp);
elseif baseline_loaded
    fprintf('  ⚠ Loaded baseline lacks impact-band fields (pre-Phase-5 file).\n');
    fprintf('    Re-run characterize_noise_baseline.m to regenerate. Falling\n');
    fprintf('    back to first-%.1fs impact-band stats for this run.\n', NOISE_BASELINE_S);
    baseline_ch0 = struct();
    baseline_ch1 = struct();
else
    baseline_ch0 = struct();
    baseline_ch1 = struct();
end

[idx_ch0, ste_ch0, ll_ch0, thr_ch0] = detect_bursts_inline(ch0_imp, fs, ...
    DET_F_MIN_HZ, DET_WIN_FACTOR, DET_NOISE_DUR_S, ...
    DET_ON_THRESH, DET_OFF_THRESH, DET_LOCKOUT_S, DET_PEAK_FLOOR_MULT, baseline_ch0);
[idx_ch1, ste_ch1, ll_ch1, thr_ch1] = detect_bursts_inline(ch1_imp, fs, ...
    DET_F_MIN_HZ, DET_WIN_FACTOR, DET_NOISE_DUR_S, ...
    DET_ON_THRESH, DET_OFF_THRESH, DET_LOCKOUT_S, DET_PEAK_FLOOR_MULT, baseline_ch1);

% ═════════════════════════════════════════════════════════════════════
%  STAGE-2 WINDOW EXTENSION (post-detection, pre-refinement)
% ═════════════════════════════════════════════════════════════════════
% detect_bursts_inline reliably finds N strikes (single-sample OFF
% prevents merging across long inter-strike gaps), but may terminate
% each window short of the visible decay extent if STE briefly dips
% below OFF mid-decay. extend_burst_windows_to_decay walks each end
% forward with hysteresis (DET_OFF_HYST_MS sustained-below required),
% capped at next-strike-start - DET_NEXT_STRIKE_MARGIN_S so windows
% can never overlap or absorb the next strike's onset.
%
% N strikes in → N windows out. Last burst is uncapped (extends to
% sustained-below or end-of-capture).
idx_ch0 = extend_burst_windows_to_decay(idx_ch0, ste_ch0, ll_ch0, thr_ch0, ...
    fs, DET_OFF_HYST_MS, DET_NEXT_STRIKE_MARGIN_S);
idx_ch1 = extend_burst_windows_to_decay(idx_ch1, ste_ch1, ll_ch1, thr_ch1, ...
    fs, DET_OFF_HYST_MS, DET_NEXT_STRIKE_MARGIN_S);

% ═════════════════════════════════════════════════════════════════════
%  STAGE 2.5 — STRONGEST-N CAP (per-channel, optional)
% ═════════════════════════════════════════════════════════════════════
% When MAX_BURSTS_CAP_GLOBAL is finite (default = inf, no cap), keep only
% the top N bursts per channel sorted by peak impact-band STE within each
% burst's window. Chronological order of the kept bursts is preserved so
% downstream code (which assumes time-ordered bursts) is unaffected.
%
% Use case: separating ghosts from weak real strikes when scalar peak-
% floor multipliers can't (Specimen_3_P2). Enabling this on a capture is
% an explicit "I trust there are exactly N strikes here" assertion —
% review the dashboard to confirm the kept bursts are the real ones.
if isfinite(MAX_BURSTS_CAP_GLOBAL)
    [idx_ch0, n_dropped_ch0] = cap_to_strongest_n(idx_ch0, ste_ch0, MAX_BURSTS_CAP_GLOBAL);
    [idx_ch1, n_dropped_ch1] = cap_to_strongest_n(idx_ch1, ste_ch1, MAX_BURSTS_CAP_GLOBAL);
    if n_dropped_ch0 > 0 || n_dropped_ch1 > 0
        fprintf('  ⚠ MAX_BURSTS_CAP=%d active — dropped: Ch0=%d  Ch1=%d (kept strongest by peak STE)\n', ...
            MAX_BURSTS_CAP_GLOBAL, n_dropped_ch0, n_dropped_ch1);
    end
end

% ═════════════════════════════════════════════════════════════════════
%  UAE-BAND BURST-WINDOW REFINEMENT (Phase 5+)
% ═════════════════════════════════════════════════════════════════════
% The impact-band detector returns burst windows that follow IMPACT-band
% structural-mode ringdown — which lasts 1–5 seconds in metallic specimens. Using
% these wide windows for analysis averages UAE signal over mostly post-
% burst noise, killing SNR / R² / τ fits.
%
% Solution: keep impact-band detection for ROBUST TRIGGERING, but find
% the actual UAE-band onset and offset within each impact-window for
% the ANALYSIS step. Walk outward from the UAE-STE peak:
%   • onset:  walk backward from peak until UAE STE drops below ON
%   • offset: walk forward  from peak until UAE STE drops below OFF
% UAE thresholds are looser than detection (we're already inside a
% confirmed impact burst — just locating the envelope edges):
%   ON  = median + 6·σ_eq    (vs 12 for detection)
%   OFF = median + 3·σ_eq    (vs 6 for detection)
% Falls back to a 200 ms fixed window if UAE peak doesn't reach the ON
% threshold (very weak UAE coupling — burst still scored, just bounded).
%
% The ORIGINAL impact-band windows are preserved as idx_ch0_imp /
% idx_ch1_imp (kept for ML feature extraction and debugging plots).
% Downstream scoring uses the refined idx_ch0 / idx_ch1.
%
% APPROACH: Hilbert-envelope based refinement.
%   1. env(t) = LPF( |hilbert(ch_bp(t))| ) — instantaneous amplitude smoothed
%      with a low-pass filter. Heavy smoothing means the envelope is monotonic
%      through the decay (no sample-to-sample jaggedness like raw STE had).
%   2. Local noise estimate: median + 3·MAD of env over the first N seconds
%      of each channel (excluding any impact-band burst that started before
%      that — defensive for early strikes).
%   3. Walk back from envelope peak until env < off_thresh (single sample OK,
%      envelope is already smooth).
%   4. Walk forward from envelope peak with HYSTERESIS: require env to remain
%      below off_thresh for HYST_MS consecutive samples before terminating.
%      Rewinds end-index to the start of the sustained-below run.
%   5. Weak-burst fallback: if envelope peak < peak_thresh (K_PEAK·MAD above
%      noise), use a fixed-width fallback window from impact start.
%   6. Walk-forward off threshold is per-burst:
%        off_thresh_eff = max(env_med + K_OFF·mad,  K_PEAK_FRAC · burst_peak)
%      For weak bursts the noise-floor term dominates (capture down to noise).
%      For strong bursts the fraction-of-peak term dominates (capture down to
%      a fixed fraction of THIS burst's peak — independent of how quiet the
%      pre-strike noise estimate was). This handles the case where pre-strike
%      noise is much quieter than during-session structural ringing residual,
%      which would otherwise leave the walk-forward extending hundreds of ms
%      past where the signal is actually meaningful.
%      Walk-back (onset) keeps the noise-floor threshold so the rising edge
%      is still found near the strike.
% (UAE_REFINE_* tuning constants are defined at the top of the script in
%  the TUNING PARAMETERS block. Do NOT redefine here.)

% Smoothed Hilbert envelope of UAE bandpass for each channel
[lpf_b, lpf_a] = butter(4, UAE_REFINE_LPF_HZ / (fs/2), 'low');
env_ch0 = filtfilt(lpf_b, lpf_a, abs(hilbert(ch0_bp)));
env_ch1 = filtfilt(lpf_b, lpf_a, abs(hilbert(ch1_bp)));

% Save impact-band windows separately (preserved for ML / debugging)
idx_ch0_imp = idx_ch0;
idx_ch1_imp = idx_ch1;

% Local noise estimate from first UAE_REFINE_NOISE_S seconds of each channel.
% Defensive: if the impact-band detector found a burst inside the noise
% window, truncate the noise sample to end before that burst.
n_noise_req = round(UAE_REFINE_NOISE_S * fs);
n_noise_ch0 = min(n_noise_req, N);
n_noise_ch1 = min(n_noise_req, N);
if ~isempty(idx_ch0_imp) && idx_ch0_imp(1,1) <= n_noise_ch0
    n_noise_ch0 = max(1, idx_ch0_imp(1,1) - 1);
end
if ~isempty(idx_ch1_imp) && idx_ch1_imp(1,1) <= n_noise_ch1
    n_noise_ch1 = max(1, idx_ch1_imp(1,1) - 1);
end

env_med_ch0 = median(env_ch0(1:n_noise_ch0));
env_mad_ch0 = max(1.4826 * mad1(env_ch0(1:n_noise_ch0)), eps);
env_med_ch1 = median(env_ch1(1:n_noise_ch1));
env_mad_ch1 = max(1.4826 * mad1(env_ch1(1:n_noise_ch1)), eps);

% Off threshold: max of additive (env_med + K_OFF·mad) and multiplicative
% (K_REL·env_med). The multiplicative term decouples the threshold from the
% per-channel mad estimate, so channels with different noise color terminate
% at the same SNR relative to noise. The additive term remains as a backstop
% for unusual noise distributions.
off_thresh_add_ch0 = env_med_ch0 + UAE_REFINE_K_OFF * env_mad_ch0;
off_thresh_mul_ch0 = UAE_REFINE_K_REL * env_med_ch0;
off_thresh_ch0     = max(off_thresh_add_ch0, off_thresh_mul_ch0);
peak_thresh_ch0    = env_med_ch0 + UAE_REFINE_K_PEAK * env_mad_ch0;

off_thresh_add_ch1 = env_med_ch1 + UAE_REFINE_K_OFF * env_mad_ch1;
off_thresh_mul_ch1 = UAE_REFINE_K_REL * env_med_ch1;
off_thresh_ch1     = max(off_thresh_add_ch1, off_thresh_mul_ch1);
peak_thresh_ch1    = env_med_ch1 + UAE_REFINE_K_PEAK * env_mad_ch1;

hyst_samp        = max(1, round(UAE_REFINE_HYST_MS * 1e-3 * fs));
fallback_samp    = round(UAE_REFINE_FALLBACK_S * fs);
peak_search_samp = max(1, round(UAE_REFINE_PEAK_SEARCH_S * fs));

% Sanity comparison: local noise (Hilbert env) vs baseline (raw STE).
% These quantities are different in units (env_med ≈ 1.25·σ for white noise
% after Rayleigh normalization, vs STE = σ direct), but should track
% proportionally if conditions match the baseline.
if off_thresh_mul_ch0 >= off_thresh_add_ch0, dom_ch0 = 'K_REL';     else, dom_ch0 = 'K_OFF*mad'; end
if off_thresh_mul_ch1 >= off_thresh_add_ch1, dom_ch1 = 'K_REL';     else, dom_ch1 = 'K_OFF*mad'; end
fprintf('  UAE-refinement noise (first %.1fs of capture):\n', UAE_REFINE_NOISE_S);
fprintf('     Ch0  env_med = %.3e   mad = %.3e   off_thresh = %.3e  [%s dominates]\n', ...
    env_med_ch0, env_mad_ch0, off_thresh_ch0, dom_ch0);
fprintf('     Ch1  env_med = %.3e   mad = %.3e   off_thresh = %.3e  [%s dominates]\n', ...
    env_med_ch1, env_mad_ch1, off_thresh_ch1, dom_ch1);
if baseline_loaded
    fprintf('     (vs baseline UAE STE — Ch0: %.3e  Ch1: %.3e)\n', ...
        nb.ch0_ste_median, nb.ch1_ste_median);
end

% Refine each channel
idx_ch0 = refine_burst_hilbert(idx_ch0_imp, env_ch0, ...
    peak_thresh_ch0, off_thresh_ch0, UAE_REFINE_K_PEAK_FRAC, hyst_samp, fallback_samp, ...
    peak_search_samp, UAE_REFINE_VERBOSE, 'Ch0', fs);
idx_ch1 = refine_burst_hilbert(idx_ch1_imp, env_ch1, ...
    peak_thresh_ch1, off_thresh_ch1, UAE_REFINE_K_PEAK_FRAC, hyst_samp, fallback_samp, ...
    peak_search_samp, UAE_REFINE_VERBOSE, 'Ch1', fs);

% Print refinement summary so the user can see the window narrowing
n0_imp = size(idx_ch0_imp, 1);  n1_imp = size(idx_ch1_imp, 1);
if n0_imp > 0 || n1_imp > 0
    fprintf('  UAE-band refinement (impact → UAE window width):\n');
    for k = 1:n0_imp
        w_imp = (idx_ch0_imp(k,2) - idx_ch0_imp(k,1)) / fs * 1000;
        w_uae = (idx_ch0(k,2)     - idx_ch0(k,1))     / fs * 1000;
        fprintf('     Ch0 #%d: %7.1f ms (impact) → %6.1f ms (UAE)\n', k, w_imp, w_uae);
    end
    for k = 1:n1_imp
        w_imp = (idx_ch1_imp(k,2) - idx_ch1_imp(k,1)) / fs * 1000;
        w_uae = (idx_ch1(k,2)     - idx_ch1(k,1))     / fs * 1000;
        fprintf('     Ch1 #%d: %7.1f ms (impact) → %6.1f ms (UAE)\n', k, w_imp, w_uae);
    end
end

% Drift check — uses UAE-band STE median (the band that matters for SNR
% scoring; impact-band drift is irrelevant to downstream quality metrics).
% Computed inline since the detector now returns impact-band STE.
% Hammer strikes contaminate < 0.1 % of samples, so capture median is still
% dominated by the noise floor — a robust drift indicator.
if baseline_loaded
    win_dur_drift     = DET_WIN_FACTOR / DET_F_MIN_HZ;
    win_n_drift       = max(1, round(win_dur_drift * fs));
    ste_ch0_bp_med    = sqrt(median(movmean(ch0_bp.^2, win_n_drift)));
    ste_ch1_bp_med    = sqrt(median(movmean(ch1_bp.^2, win_n_drift)));
    drift_db_ch0 = 20*log10(ste_ch0_bp_med / max(nb.ch0_ste_median, eps));
    drift_db_ch1 = 20*log10(ste_ch1_bp_med / max(nb.ch1_ste_median, eps));
    if abs(drift_db_ch0) > DRIFT_WARN_DB || abs(drift_db_ch1) > DRIFT_WARN_DB
        fprintf('  DRIFT WARNING — UAE-band noise level has shifted since baseline:\n');
        fprintf('     Ch0 %+.1f dB   Ch1 %+.1f dB   (|Δ| > %.0f dB threshold)\n', ...
            drift_db_ch0, drift_db_ch1, DRIFT_WARN_DB);
        fprintf('     Consider re-running characterize_noise_baseline.m.\n');
    else
        fprintf('  Drift check — Ch0 %+.2f dB   Ch1 %+.2f dB   (within ±%.0f dB)\n', ...
            drift_db_ch0, drift_db_ch1, DRIFT_WARN_DB);
    end
end

% Apply head/tail extensions
idx_ch0 = extend_burst_indices(idx_ch0, fs, DET_HEAD_EXT_S, DET_TAIL_EXT_S, N);
idx_ch1 = extend_burst_indices(idx_ch1, fs, DET_HEAD_EXT_S, DET_TAIL_EXT_S, N);

n0 = size(idx_ch0, 1);
n1 = size(idx_ch1, 1);
fprintf('  Bursts detected — Ch0: %d   Ch1: %d   (expected %d)\n', ...
    n0, n1, N_STRIKES_EXPECTED);

% Burst-count flag
count_mismatch_ch0 = (n0 ~= N_STRIKES_EXPECTED);
count_mismatch_ch1 = (n1 ~= N_STRIKES_EXPECTED);

% ═════════════════════════════════════════════════════════════════════
%  PER-BURST QUALITY METRICS
% ═════════════════════════════════════════════════════════════════════
% (ch0_imp, ch1_imp already computed above before burst detection — Phase 5
% architecture moved the impact-band filter creation up.)

% Noise RMS references — from baseline if available, else from first 1 s.
if baseline_loaded
    noise_rms_ch0     = nb.ch0_noise_rms_bp;
    noise_rms_ch1     = nb.ch1_noise_rms_bp;
    noise_rms_imp_ch0 = nb.ch0_noise_rms_imp;
    noise_rms_imp_ch1 = nb.ch1_noise_rms_imp;
    fprintf('  Noise RMS (baseline)  — Ch0: %.2e V   Ch1: %.2e V  (bp 20–80 kHz)\n', ...
        noise_rms_ch0, noise_rms_ch1);
    fprintf('                          Ch0: %.2e V   Ch1: %.2e V  (imp 1–10 kHz)\n', ...
        noise_rms_imp_ch0, noise_rms_imp_ch1);
else
    n_noise = round(NOISE_BASELINE_S * fs);
    noise_rms_ch0     = rms(ch0_bp(1:n_noise));
    noise_rms_ch1     = rms(ch1_bp(1:n_noise));
    noise_rms_imp_ch0 = rms(ch0_imp(1:n_noise));
    noise_rms_imp_ch1 = rms(ch1_imp(1:n_noise));
    fprintf('  Noise RMS (first %.1fs) — Ch0: %.2e V   Ch1: %.2e V  (bp 20–80 kHz)\n', ...
        NOISE_BASELINE_S, noise_rms_ch0, noise_rms_ch1);
end

% Score each channel's bursts independently.
metrics_ch0 = score_bursts(ch0_bp, ch0_imp, ch0_raw, idx_ch0, fs, ...
    noise_rms_ch0, noise_rms_imp_ch0, SAT_LIMIT, ...
    DECAY_DYNAMIC_RANGE_DB, WELCH_TARGET_AVG, PSD_BAND_HZ, ...
    IMPACT_MIN_DB_OVER_NOISE);
metrics_ch1 = score_bursts(ch1_bp, ch1_imp, ch1_raw, idx_ch1, fs, ...
    noise_rms_ch1, noise_rms_imp_ch1, SAT_LIMIT, ...
    DECAY_DYNAMIC_RANGE_DB, WELCH_TARGET_AVG, PSD_BAND_HZ, ...
    IMPACT_MIN_DB_OVER_NOISE);

% Verdict per burst per channel
verdict_ch0 = compute_verdicts(metrics_ch0, ...
    SNR_GOOD_DB, SNR_MARG_DB, R2_GOOD, R2_MARG, PSDCORR_GOOD, PSDCORR_MARG, ...
    TAU_MIN_MS, TAU_MAX_MS);
verdict_ch1 = compute_verdicts(metrics_ch1, ...
    SNR_GOOD_DB, SNR_MARG_DB, R2_GOOD, R2_MARG, PSDCORR_GOOD, PSDCORR_MARG, ...
    TAU_MIN_MS, TAU_MAX_MS);

% ═════════════════════════════════════════════════════════════════════
%  FIGURES — three windows, screen-positioned for HP Spectre
% ═════════════════════════════════════════════════════════════════════
scrsz   = get(groot, 'ScreenSize');
screen_w = scrsz(3); screen_h = scrsz(4);
margin   = 8; taskbar = 80;

% Fig 1 — Verdict Dashboard (top-left, ~half width × half height)
dash_w = floor(screen_w * 0.45);
dash_h = floor((screen_h - taskbar) * 0.55);
fig1   = figure('Name', 'Verdict Dashboard', 'Color', 'w', ...
    'NumberTitle', 'off', ...
    'Position', [margin, screen_h - taskbar - dash_h - margin, dash_w, dash_h]);
draw_verdict_dashboard(fig1, load_name, n0, n1, N_STRIKES_EXPECTED, ...
    metrics_ch0, metrics_ch1, verdict_ch0, verdict_ch1, fs, N);

% Fig 2 — Full time-domain with bursts highlighted (right side, full height)
fig2_w = screen_w - dash_w - 3*margin;
fig2_h = screen_h - taskbar - 2*margin;
fig2   = figure('Name', 'Time Domain — Bursts', 'Color', 'w', ...
    'NumberTitle', 'off', ...
    'Position', [dash_w + 2*margin, margin, fig2_w, fig2_h]);
draw_time_domain(fig2, t, ch0_bp, ch1_bp, idx_ch0, idx_ch1, ...
    ste_ch0, ste_ch1, ll_ch0, ll_ch1, thr_ch0, thr_ch1, ...
    BP_LOW_HZ, BP_HIGH_HZ);

% Fig 3 — Zoomed burst starts (bottom-left, fills space below dashboard)
fig3_h = screen_h - taskbar - dash_h - 3*margin;
fig3   = figure('Name', 'Zoomed Burst Starts', 'Color', 'w', ...
    'NumberTitle', 'off', ...
    'Position', [margin, margin, dash_w, fig3_h]);
draw_zoomed_starts(fig3, t, ch0_bp, ch1_bp, idx_ch0, idx_ch1, fs);

% Fig 4 — Raw time-domain (no compensation, no bandpass) with burst overlays.
% Shows BOTH the impact-band window (pink, wide — what detector saw) and the
% UAE-refined window (green, narrow — what scoring uses). Useful for visual
% verification of refinement and as a reference view of the unprocessed signal.
fig4 = figure('Name', 'Raw Time Domain — Bursts', 'Color', 'w', ...
    'NumberTitle', 'off');
draw_raw_time_domain(fig4, t, ch0_V, ch1_V, idx_ch0, idx_ch1, ...
    idx_ch0_imp, idx_ch1_imp);

drawnow;
figure(fig1);

% ═════════════════════════════════════════════════════════════════════
%  KEEP / SKIP / KEEP_NOTE PROMPT
% ═════════════════════════════════════════════════════════════════════
fprintf('\n');
fprintf('  ─────────────────────────────────────────────────────────\n');
if BATCH_MODE
    fprintf('   [%d / %d]   %s   Bursts Ch0=%d Ch1=%d (expected %d)\n', ...
        batch_idx, n_total_to_process, load_name, n0, n1, N_STRIKES_EXPECTED);
    fprintf('  ─────────────────────────────────────────────────────────\n');
end
fprintf('   DECISION:  [Enter / k] = Keep & save burst file           \n');
fprintf('              [n]         = Keep & save with note            \n');
fprintf('              [s]         = Skip (no save, no manifest entry)\n');
fprintf('  ─────────────────────────────────────────────────────────\n');
choice = input('   Choice: ', 's');
choice = lower(strtrim(choice));

decision   = 'KEEP';
note_text  = '';
do_save    = true;
do_manifest = true;

switch choice
    case {'', 'k'}
        decision = 'KEEP';
    case 'n'
        note_text = input('   Note: ', 's');
        decision  = 'KEEP_NOTE';
    case 's'
        decision   = 'SKIP';
        do_save    = false;
        do_manifest = false;
        fprintf('   Skipped — no burst file written, no manifest update.\n');
    otherwise
        decision = 'KEEP';
        fprintf('   Unrecognized choice — defaulting to KEEP.\n');
end

% ═════════════════════════════════════════════════════════════════════
%  SAVE BURST FILE  (per-strike clips, 2 windows: imp-wide raw + UAE-narrow BP)
%  Active in batch mode OR single-file mode when BURST_SAVE_IN_SINGLE_MODE.
% ═════════════════════════════════════════════════════════════════════
save_active = do_save && (BATCH_MODE || BURST_SAVE_IN_SINGLE_MODE);
if save_active
    burst_filename = sprintf('%s_bursts.mat', basename_no_ext);
    burst_path     = fullfile(BURST_OUT_DIR, burst_filename);

    save_burst_data(burst_path, basename_no_ext, load_name, filepath, ...
        fs, N, SCRIPT_VERSION, decision, note_text, ...
        N_STRIKES_EXPECTED, n0, n1, ...
        idx_ch0, idx_ch1, idx_ch0_imp, idx_ch1_imp, ...
        ch0_comp, ch1_comp, ch0_bp, ch1_bp);

    fprintf('   Burst file saved: %s\n', burst_filename);
elseif do_save && ~BATCH_MODE && ~BURST_SAVE_IN_SINGLE_MODE
    fprintf('   (Single-file mode, save disabled — set BURST_SAVE_IN_SINGLE_MODE=true to enable.)\n');
end

% ═════════════════════════════════════════════════════════════════════
%  MANIFEST UPDATE — UPSERT  (replace existing row by basename match,
%  else append). Lets you re-tune a problem capture in single-file mode
%  and have the manifest row update cleanly instead of duplicating.
% ═════════════════════════════════════════════════════════════════════
manifest_active = do_manifest && (BATCH_MODE || BURST_SAVE_IN_SINGLE_MODE);
if manifest_active
    new_row = make_manifest_row(basename_no_ext, burst_path, decision, ...
        n0, n1, N_STRIKES_EXPECTED, SCRIPT_VERSION);
    if ~isempty(manifest)
        match_idx = find(strcmp(manifest.basename, basename_no_ext), 1);
    else
        match_idx = [];
    end
    if isempty(match_idx)
        manifest = [manifest; new_row]; %#ok<AGROW>
        op_label = 'inserted';
    else
        manifest(match_idx, :) = new_row;
        op_label = 'replaced';
    end
    save(manifest_path, 'manifest', '-v7.3');
    fprintf('   Manifest %s: %d entries total.\n', op_label, height(manifest));
end

% ═════════════════════════════════════════════════════════════════════
%  SINGLE-FILE LEGACY CSV LOG  (only in single-file mode)
% ═════════════════════════════════════════════════════════════════════
if ~BATCH_MODE
    log_path = fullfile(DATA_DIR, LOG_FILENAME);
    append_field_log(log_path, load_name, n0, n1, N_STRIKES_EXPECTED, ...
        metrics_ch0, metrics_ch1, verdict_ch0, verdict_ch1, ...
        decision, note_text, fs);
    fprintf('\n  Logged to: %s\n', log_path);
end

fprintf('  Done.\n');

end  % end batch loop ─────────────────────────────────────────────────────

% ═════════════════════════════════════════════════════════════════════
%  BATCH SUMMARY
% ═════════════════════════════════════════════════════════════════════
if BATCH_MODE
    fprintf('\n');
    fprintf('═══════════════════════════════════════════════════════════════\n');
    fprintf('  BATCH COMPLETE   |   Manifest: %s\n', manifest_path);
    fprintf('═══════════════════════════════════════════════════════════════\n');
    if ~isempty(manifest)
        n_keep      = sum(strcmp(manifest.decision, 'KEEP'));
        n_keep_note = sum(strcmp(manifest.decision, 'KEEP_NOTE'));
        fprintf('  Total in manifest: %d   (KEEP=%d, KEEP_NOTE=%d)\n', ...
            height(manifest), n_keep, n_keep_note);
        n_count_mismatch = sum( (manifest.n_strikes_ch0 ~= manifest.expected_strikes) | ...
                                (manifest.n_strikes_ch1 ~= manifest.expected_strikes) );
        if n_count_mismatch > 0
            fprintf('  ⚠ %d entries have strike-count mismatch — review manifest.\n', n_count_mismatch);
        end
    end
end



%% ════════════════════════════════════════════════════════════════════
%  ─────────────────  LOCAL FUNCTIONS  ────────────────────────────────
% ═════════════════════════════════════════════════════════════════════

function [burst_idx, ste, ll, thr] = detect_bursts_inline(sig, fs, f_min, ...
    win_factor, noise_dur_s, on_mult, off_mult, lockout_s, peak_floor_mult, ...
    baseline_stats)
% Inlined STE + LL dual-contour burst detector.
%   sig: 1D signal (band-passed compensated)
%   fs:  sample rate
%   baseline_stats: struct with fields ste_median, ste_mad, ll_median, ll_mad
%                   from characterize_noise_baseline.m. Pass struct() (empty)
%                   to fall back to first-noise_dur_s computation.
%   Returns Nx2 [start, end] sample indices.

    if nargin < 10
        baseline_stats = struct();
    end

    win_dur     = win_factor / f_min;
    win_samples = max(1, round(win_dur * fs));
    win         = ones(win_samples, 1);

    % STE on already-band-passed signal
    sq    = sig.^2;
    ste   = sqrt(conv(sq, win, 'same') / win_samples);

    % Line Length on band-passed signal
    abs_d = [0; abs(diff(sig))];
    ll    = conv(abs_d, win, 'same');

    % Noise statistics — from baseline if provided, else first noise_dur_s
    % of the contour. Baseline path uses site-calibrated stats from
    % characterize_noise_baseline.m (produced from a dedicated noise-only
    % capture; much tighter than 1 s of in-capture pre-roll).
    if ~isempty(fieldnames(baseline_stats))
        mu_ste = baseline_stats.ste_median;
        sd_ste = max(baseline_stats.ste_mad, eps);
        mu_ll  = baseline_stats.ll_median;
        sd_ll  = max(baseline_stats.ll_mad,  eps);
    else
        n_noise = max(1, round(noise_dur_s * fs));
        n_noise = min(n_noise, length(ste));
        % Robust noise statistics: median + 1.4826·MAD (σ-equivalent).
        % `eps` floor guards all-quantized input where MAD can collapse to zero.
        mu_ste = median(ste(1:n_noise));
        sd_ste = max(1.4826 * mad1(ste(1:n_noise)), eps);
        mu_ll  = median(ll(1:n_noise));
        sd_ll  = max(1.4826 * mad1(ll(1:n_noise)), eps);
    end

    thr.on_ste  = mu_ste + on_mult  * sd_ste;
    thr.off_ste = mu_ste + off_mult * sd_ste;
    thr.on_ll   = mu_ll  + on_mult  * sd_ll;
    thr.off_ll  = mu_ll  + off_mult * sd_ll;

    % Peak-floor for in-state-machine commit gate. Bursts whose running peak
    % STE never reaches this floor are discarded WITHOUT setting lockout —
    % so they cannot block detection of nearby real strikes.
    %
    % Architectural note (Tier 2.1 fix): in earlier versions, the peak-floor
    % was applied as a POST-state-machine filter. This created a dead-zone
    % bug: a small noise blip could trigger the state machine, set lockout,
    % block a real strike from triggering during the lockout window, then
    % itself be rejected by the post-filter — leaving a region with no
    % detection at all. Moving the peak-floor INSIDE the state machine (only
    % committing bursts and only setting lockout if the peak threshold is
    % met) eliminates this failure mode entirely.
    peak_floor = peak_floor_mult * mu_ste;

    % Hysteresis state machine with inline peak-floor commit gate
    burst_idx     = zeros(0, 2);
    is_active     = false;
    lockout_end   = 0;
    lockout_samp  = round(lockout_s * fs);
    burst_start   = 0;
    burst_peak    = 0;     % running peak STE within the active burst

    for i = 1:length(sig)
        if ~is_active && i > lockout_end
            if (ste(i) > thr.on_ste) && (ll(i) > thr.on_ll)
                is_active   = true;
                burst_start = i;
                burst_peak  = ste(i);
            end
        elseif is_active
            % Track running peak
            if ste(i) > burst_peak
                burst_peak = ste(i);
            end
            if (ste(i) < thr.off_ste) && (ll(i) < thr.off_ll)
                is_active = false;
                burst_end = i;
                % Commit + set lockout ONLY if the running peak exceeded the
                % floor (i.e., this was a real-amplitude event). Otherwise
                % discard silently — no commit, no lockout.
                if peak_floor_mult <= 0 || burst_peak >= peak_floor
                    burst_idx   = [burst_idx; burst_start, burst_end];
                    lockout_end = burst_end + lockout_samp;
                end
            end
        end
    end
    % If still active at end, apply same commit gate
    if is_active
        if peak_floor_mult <= 0 || burst_peak >= peak_floor
            burst_idx = [burst_idx; burst_start, length(sig)];
        end
    end
end


function idx_out = extend_burst_windows_to_decay(burst_idx, ste, ll, thr, ...
    fs, hyst_ms, margin_s)
% STAGE-2 window extension. Walk each burst's end-index forward with
% hysteresis until STE & LL are sustained-below the OFF thresholds for
% hyst_ms consecutive samples, OR until we reach the cap (next-burst
% start - margin_samp). The last burst has no cap; it walks to
% sustained-below or to end-of-signal.
%
% Inputs:
%   burst_idx  Nx2 [start, end] sample indices from detect_bursts_inline
%   ste        full-length STE contour from detector
%   ll         full-length LL contour from detector
%   thr        struct with fields off_ste, off_ll
%   fs         sample rate (Hz)
%   hyst_ms    consecutive-below duration required (ms)
%   margin_s   minimum gap between burst-N end and burst-(N+1) start (s)
%
% Output:
%   idx_out    Nx2 with end-indices extended (start-indices untouched)
%
% Guarantees:
%   - N strikes in → N windows out (no merging, no addition)
%   - Windows never overlap (capped at next_start - margin_samp)
%   - Each window's end >= original end (extension only, never truncation)
    if isempty(burst_idx)
        idx_out = burst_idx;
        return;
    end

    n_bursts   = size(burst_idx, 1);
    hyst_samp  = max(1, round(hyst_ms * 1e-3 * fs));
    margin_samp = max(0, round(margin_s * fs));
    N          = length(ste);
    idx_out    = burst_idx;

    for k = 1:n_bursts
        end_k   = burst_idx(k, 2);

        % Determine cap: for non-last bursts, cap = next_start - margin
        % For last burst, no cap (walk to end of signal).
        if k < n_bursts
            cap = burst_idx(k+1, 1) - margin_samp;
            % Defensive: if margin pushes cap before current end (shouldn't
            % happen with margin=100 ms and lockout=1 s, but guard anyway),
            % leave window unchanged.
            if cap <= end_k
                continue;
            end
        else
            cap = N;
        end
        cap = min(cap, N);

        % Walk forward from current end_k. Track sustained-below run;
        % rewind to start of run when hysteresis fires.
        below_count    = 0;
        below_run_start = end_k;
        new_end = cap;  % default if we hit cap before sustained-below

        for i = end_k:cap
            if (ste(i) < thr.off_ste) && (ll(i) < thr.off_ll)
                if below_count == 0
                    below_run_start = i;
                end
                below_count = below_count + 1;
                if below_count >= hyst_samp
                    new_end = below_run_start;
                    break;
                end
            else
                below_count = 0;
            end
        end

        % new_end must not regress below original end (extension only)
        idx_out(k, 2) = max(end_k, new_end);
    end
end


function [idx_out, n_dropped] = cap_to_strongest_n(burst_idx, ste, max_n)
% keep only the top max_n bursts ranked by peak impact-band STE
% within each burst's window. Chronological order of the kept bursts is
% preserved (output is time-sorted, not strength-sorted).
%
% Inputs:
%   burst_idx  Nx2 [start, end] sample indices
%   ste        full-length impact-band STE contour from the detector
%   max_n      maximum number of bursts to keep (use inf for no cap)
%
% Outputs:
%   idx_out    Mx2 with M = min(N, max_n), in chronological order
%   n_dropped  number of bursts dropped (N - M)
    n_in = size(burst_idx, 1);
    if n_in <= max_n
        idx_out = burst_idx;
        n_dropped = 0;
        return;
    end

    peak_ste = zeros(n_in, 1);
    for k = 1:n_in
        s = burst_idx(k, 1);
        e = burst_idx(k, 2);
        peak_ste(k) = max(ste(s:e));
    end

    [~, sort_by_strength] = sort(peak_ste, 'descend');
    keep_idx = sort(sort_by_strength(1:max_n));   % chronological order
    idx_out  = burst_idx(keep_idx, :);
    n_dropped = n_in - max_n;
end


function idx_ext = extend_burst_indices(burst_idx, fs, head_s, tail_s, N)
% Apply head and tail extensions, clamped to [1, N].
    if isempty(burst_idx)
        idx_ext = burst_idx;
        return;
    end
    head_samp = round(head_s * fs);
    tail_samp = round(tail_s * fs);
    idx_ext = burst_idx;
    idx_ext(:,1) = max(1, idx_ext(:,1) - head_samp);
    idx_ext(:,2) = min(N, idx_ext(:,2) + tail_samp);
end


function M = score_bursts(sig_bp, sig_imp, sig_raw, burst_idx, fs, ...
    noise_rms_bp, noise_rms_imp, sat_limit, decay_db_range, ...
    welch_target_avg, psd_band_hz, impact_min_db)
% Compute SNR, decay R², PSD correlation, saturation, and impact strength
% for each burst. Returns struct array M(k) with one entry per burst.

    nb = size(burst_idx, 1);
    if nb == 0
        M = struct('snr_db',{},'decay_r2',{},'tau_ms',{},'psd_corr',{}, ...
                   'saturated',{},'impact_db',{},'impact_pass',{}, ...
                   'pxx',{},'f_psd',{},'idx',{});
        return;
    end

    % First pass: extract bursts and compute everything except PSD correlation
    M(nb) = struct('snr_db',NaN,'decay_r2',NaN,'tau_ms',NaN,'psd_corr',NaN, ...
                   'saturated',false,'impact_db',NaN,'impact_pass',false, ...
                   'pxx',[],'f_psd',[],'idx',[0 0]);
    pxx_all = cell(nb, 1);

    for k = 1:nb
        i1 = burst_idx(k, 1); i2 = burst_idx(k, 2);
        seg_bp  = sig_bp (i1:i2);
        seg_imp = sig_imp(i1:i2);
        seg_raw = sig_raw(i1:i2);

        M(k).idx = [i1, i2];

        % Saturation check on raw ADC counts within burst window
        M(k).saturated = any(abs(seg_raw) >= sat_limit);

        % SNR (band-passed)
        burst_rms = rms(seg_bp);
        M(k).snr_db = 20*log10(max(burst_rms, eps) / max(noise_rms_bp, eps));

        % Impact strength (1–10 kHz energy above structural-mode noise floor)
        imp_rms = rms(seg_imp);
        M(k).impact_db   = 20*log10(max(imp_rms, eps) / max(noise_rms_imp, eps));
        M(k).impact_pass = M(k).impact_db >= impact_min_db;

        % Decay fit on Hilbert envelope of band-passed burst
        [r2, tau_ms] = fit_decay_r2(seg_bp, fs, decay_db_range);
        M(k).decay_r2 = r2;
        M(k).tau_ms   = tau_ms;

        % Welch PSD over the band of interest (for inter-strike correlation)
        n_seg     = length(seg_bp);
        nfft_raw  = max(256, 2 * n_seg / welch_target_avg);
        nfft      = 2^max(8, round(log2(nfft_raw)));
        nfft      = min(nfft, 2^floor(log2(n_seg)));
        if nfft < 64
            nfft = min(64, n_seg);
        end
        win       = hann(nfft);
        nov       = nfft / 2;
        try
            [pxx, f_psd] = pwelch(seg_bp, win, nov, nfft, fs, 'power');
        catch
            % Fall back to single-segment periodogram if burst is tiny
            [pxx, f_psd] = periodogram(seg_bp, hann(n_seg), n_seg, fs, 'power');
        end
        M(k).pxx   = pxx;
        M(k).f_psd = f_psd;

        % Restrict to the analysis band for correlation
        bmask = (f_psd >= psd_band_hz(1)) & (f_psd <= psd_band_hz(2));
        pxx_all{k} = pxx(bmask);   % store LINEAR PSD; single dB conversion below
    end

    % Second pass: PSD correlation = corr(this PSD vs template PSD)
    %
    % Template = the burst with the HIGHEST mean correlation to all others
    % (Tier 2.1). This is the most "representative" burst — by definition,
    % the one whose PSD shape is closest to all the rest. Robust to outlier
    % strikes where one strike has different PSD character (different
    % hammer angle, different coupling) from the others.
    %
    % Why not argmax(SNR)?  SNR doesn't measure shape similarity. A loud
    % strike with anomalous PSD (e.g., struck a weld-bead instead of clean
    % steel) would become the template and force every other strike to
    % correlate against an outlier — flagging real, consistent strikes as
    % BAD. Median-correlation selection picks the strike that "agrees most"
    % with the population, naturally excluding outliers.
    %
    % The template-strike's own PSDcorr is set to NaN (self-correlation = 1
    % is uninformative; verdict logic treats NaN PSDcorr as "passes" so the
    % template is judged on SNR/R²/impact/τ alone).
    if nb >= 2
        % All burst PSDs in band must share frequency vector. Normalize by
        % truncating to common length to handle small NFFT differences.
        L = min(cellfun(@length, pxx_all));
        P = zeros(L, nb);
        for k = 1:nb
            P(:,k) = pxx_all{k}(1:L);
        end

        % Compute pairwise correlation matrix in dB-domain
        Pdb = 10*log10(P + eps);   % the ONE dB conversion (P is linear)
        Cmat = corrcoef(Pdb);   % nb × nb matrix
        % Mean correlation of each burst to all others (off-diagonal)
        mean_corr = (sum(Cmat, 2) - 1) / (nb - 1);   % subtract self (=1)
        [~, k_template] = max(mean_corr);
        P_template_db = Pdb(:, k_template);

        for k = 1:nb
            if k == k_template
                M(k).psd_corr = NaN;     % template gets NaN (self = 1)
                continue;
            end
            cmat = corrcoef(Pdb(:,k), P_template_db);
            M(k).psd_corr = cmat(1, 2);
        end
    else
        for k = 1:nb
            M(k).psd_corr = NaN;
        end
    end
end


function [r2, tau_ms] = fit_decay_r2(burst, fs, dynamic_range_db)
% Fit log(envelope) = log(A) − t/τ from peak to peak − dynamic_range_db.
% Returns R² of fit (in log domain, weighted by envelope amplitude).
% Returns NaN if the burst is too short or no clean decay region exists.

    if length(burst) < round(0.005 * fs)   % less than 5 ms → useless
        r2 = NaN; tau_ms = NaN; return;
    end

    % Hilbert envelope, smoothed
    env = abs(hilbert(burst));
    sm_win = max(1, round(0.001 * fs));   % 1 ms moving average
    env = movmean(env, sm_win);

    [pk, pk_idx] = max(env);
    if pk <= 0 || pk_idx >= length(env)
        r2 = NaN; tau_ms = NaN; return;
    end

    tail = env(pk_idx:end);
    t_tail = (0:length(tail)-1)' / fs;

    % Cut at peak − dynamic_range_db
    cutoff = pk * 10^(-dynamic_range_db/20);
    end_idx = find(tail < cutoff, 1, 'first');
    if isempty(end_idx) || end_idx < 10
        end_idx = length(tail);
    end
    fit_y = tail(1:end_idx);
    fit_t = t_tail(1:end_idx);

    % Weighted log-linear fit (weights = envelope amplitude)
    Y = log(max(fit_y, eps));
    w = fit_y;
    sw = sum(w);
    t_bar = sum(w .* fit_t) / sw;
    Y_bar = sum(w .* Y)     / sw;
    num = sum(w .* (fit_t - t_bar) .* (Y - Y_bar));
    den = sum(w .* (fit_t - t_bar).^2);
    if den <= 0
        r2 = NaN; tau_ms = NaN; return;
    end
    slope = num / den;
    icpt  = Y_bar - slope * t_bar;
    Y_hat = slope * fit_t + icpt;

    SST = sum(w .* (Y - Y_bar).^2);
    SSE = sum(w .* (Y - Y_hat).^2);
    if SST <= 0
        r2 = NaN;
    else
        r2 = 1 - SSE / SST;
    end

    if slope >= 0
        tau_ms = NaN;   % no decay (rising or flat) — physically implausible
    else
        tau_ms = -1000 / slope;
    end
end


function V = compute_verdicts(M, snr_g, snr_m, r2_g, r2_m, pc_g, pc_m, ...
                              tau_min_ms, tau_max_ms)
% Returns struct array V(k).{label, color} for each burst.
% Label: 'GOOD' / 'MARG' / 'BAD' / 'SAT'  (saturation overrides)
%
% Tier 2 hard gates (applied before GOOD/MARG/BAD classification):
%   - impact_pass MUST be true (energy in 1–10 kHz band ≥ threshold)
%   - tau_ms MUST be finite and in [tau_min_ms, tau_max_ms]
% Failing either gate → BAD regardless of other metrics. These are physical
% sanity checks: ghosts produce ring-down fits with τ > 100 ms or NaN, and
% trivial impact-band content. Real strikes have τ ≈ 4–15 ms and substantial
% structural-mode excitation.
    nb = length(M);
    % Guard: empty input → return 0×0 struct array with the same fields.
    % MATLAB's V(nb) = struct(...) preallocation idiom fails when nb == 0
    % ("Array indices must be positive integers"). This happens when a
    % channel detects zero bursts (e.g. very quiet sensor, all candidates
    % rejected by the peak-floor gate) — a legitimate field condition, not
    % an error. Caller (count_verdicts, draw_verdict_dashboard) handles
    % empty V correctly.
    if nb == 0
        V = repmat(struct('label','', 'color',[0 0 0]), 0, 0);
        return;
    end
    V(nb) = struct('label','BAD','color',[1 0.6 0.6]);
    for k = 1:nb
        if M(k).saturated
            V(k).label = 'SAT';
            V(k).color = [1 0.4 0.4];
            continue;
        end

        % Hard gates — physical sanity. Failing either means this is not
        % a real structural-mode hammer-strike ring-down.
        tau_ok = ~isnan(M(k).tau_ms) && ...
                 (M(k).tau_ms >= tau_min_ms) && ...
                 (M(k).tau_ms <= tau_max_ms);
        if ~M(k).impact_pass || ~tau_ok
            V(k).label = 'BAD';
            V(k).color = [1.0 0.65 0.65];
            continue;
        end

        % PSDcorr = NaN happens for the template burst (highest-SNR strike,
        % its own PSD is the reference). Treat NaN as "passes" — judge on
        % SNR + R² alone. Single-burst captures also produce NaN (no
        % comparison possible) and get the same treatment.
        pc = M(k).psd_corr;
        pc_good_ok = isnan(pc) || (pc >= pc_g);
        pc_marg_ok = isnan(pc) || (pc >= pc_m);

        is_good = (M(k).snr_db   >= snr_g) && ...
                  (M(k).decay_r2 >= r2_g)  && pc_good_ok;
        is_marg = (M(k).snr_db   >= snr_m) && ...
                  (M(k).decay_r2 >= r2_m)  && pc_marg_ok;
        if is_good
            V(k).label = 'GOOD'; V(k).color = [0.7 1.0 0.7];
        elseif is_marg
            V(k).label = 'MARG'; V(k).color = [1.0 0.95 0.6];
        else
            V(k).label = 'BAD';  V(k).color = [1.0 0.65 0.65];
        end
    end
end


function draw_verdict_dashboard(fig, load_name, n0, n1, n_exp, ...
    M0, M1, V0, V1, fs, N)
% Render the verdict dashboard as a colored grid using uitable + axes labels.
    figure(fig); clf;
    set(fig, 'Color', 'w');

    % ── Header text ──
    any_sat = (~isempty(M0) && any([M0.saturated])) || ...
              (~isempty(M1) && any([M1.saturated]));
    cnt_ok = (n0 == n_exp) && (n1 == n_exp);

    header_color = [0.95 0.95 0.95];
    if any_sat,    header_color = [1.0 0.5 0.5]; end
    if ~cnt_ok && ~any_sat, header_color = [1.0 0.85 0.5]; end

    uicontrol(fig, 'Style', 'text', 'Units', 'normalized', ...
        'Position', [0 0.92 1 0.08], ...
        'BackgroundColor', header_color, ...
        'FontWeight', 'bold', 'FontSize', 11, ...
        'String', sprintf('  %s   |   Fs=%.1f kSPS   |   %.1fs   |   Bursts: Ch0=%d  Ch1=%d  (expected %d)%s', ...
            load_name, fs/1e3, N/fs, n0, n1, n_exp, ...
            ternary(any_sat, '   ⚠ SATURATION DETECTED', '')), ...
        'HorizontalAlignment', 'left');

    % ── Grid header row (Strike 1 / Strike 2 / Strike 3) ──
    n_max = max([n_exp, n0, n1]);
    col_h = 0.05;
    grid_top = 0.86;
    cell_h   = (grid_top - 0.05) / 2;
    label_w  = 0.10;
    cell_w   = (1 - label_w - 0.02) / n_max;

    for s = 1:n_max
        uicontrol(fig, 'Style', 'text', 'Units', 'normalized', ...
            'Position', [label_w + (s-1)*cell_w, grid_top, cell_w, col_h], ...
            'BackgroundColor', [0.85 0.85 0.85], ...
            'FontWeight', 'bold', 'FontSize', 10, ...
            'String', sprintf('Strike %d', s));
    end

    % Row labels
    uicontrol(fig, 'Style', 'text', 'Units', 'normalized', ...
        'Position', [0.005, grid_top - cell_h, label_w - 0.01, cell_h], ...
        'BackgroundColor', [0.85 0.85 0.85], ...
        'FontWeight', 'bold', 'FontSize', 11, 'String', 'Ch0');
    uicontrol(fig, 'Style', 'text', 'Units', 'normalized', ...
        'Position', [0.005, grid_top - 2*cell_h, label_w - 0.01, cell_h], ...
        'BackgroundColor', [0.85 0.85 0.85], ...
        'FontWeight', 'bold', 'FontSize', 11, 'String', 'Ch1');

    % Cells
    for s = 1:n_max
        x = label_w + (s-1) * cell_w;
        % Ch0
        if s <= n0
            cell_str = format_cell(M0(s), V0(s));
            cell_col = V0(s).color;
        else
            cell_str = sprintf('— missing —'); cell_col = [0.9 0.9 0.9];
        end
        uicontrol(fig, 'Style', 'text', 'Units', 'normalized', ...
            'Position', [x, grid_top - cell_h, cell_w - 0.005, cell_h - 0.005], ...
            'BackgroundColor', cell_col, ...
            'FontName', 'Consolas', 'FontSize', 9, ...
            'String', cell_str, 'HorizontalAlignment', 'left');
        % Ch1
        if s <= n1
            cell_str = format_cell(M1(s), V1(s));
            cell_col = V1(s).color;
        else
            cell_str = sprintf('— missing —'); cell_col = [0.9 0.9 0.9];
        end
        uicontrol(fig, 'Style', 'text', 'Units', 'normalized', ...
            'Position', [x, grid_top - 2*cell_h, cell_w - 0.005, cell_h - 0.005], ...
            'BackgroundColor', cell_col, ...
            'FontName', 'Consolas', 'FontSize', 9, ...
            'String', cell_str, 'HorizontalAlignment', 'left');
    end

    % Footer summary
    [n_g0, n_m0, n_b0] = count_verdicts(V0);
    [n_g1, n_m1, n_b1] = count_verdicts(V1);
    foot_str = sprintf('  Ch0:  %d GOOD   %d MARG   %d BAD       Ch1:  %d GOOD   %d MARG   %d BAD', ...
        n_g0, n_m0, n_b0, n_g1, n_m1, n_b1);
    uicontrol(fig, 'Style', 'text', 'Units', 'normalized', ...
        'Position', [0 0 1 0.04], ...
        'BackgroundColor', [0.92 0.92 0.92], 'FontSize', 10, ...
        'String', foot_str, 'HorizontalAlignment', 'left');
end


function s = format_cell(M, V)
    sat_tag = '';
    if M.saturated, sat_tag = '  [SAT]'; end
    if isnan(M.tau_ms)
        tau_str = '  τ=  N/A';
    else
        tau_str = sprintf('  τ=%5.1f ms', M.tau_ms);
    end
    imp_tag = '';
    if ~M.impact_pass, imp_tag = '  ⚠low impact'; end
    if isnan(M.psd_corr)
        % Template burst (own PSD is the reference for the rest) — flag it
        pc_str = '  ref ';
    else
        pc_str = sprintf('%5.3f', M.psd_corr);
    end
    s = sprintf([' [%s]%s\n' ...
                 ' SNR    : %+5.1f dB\n' ...
                 ' R²     : %5.3f\n' ...
                 ' PSDcorr: %s\n' ...
                 ' Imp dB : %+5.1f%s\n' ...
                 '%s'], ...
        V.label, sat_tag, M.snr_db, M.decay_r2, pc_str, ...
        M.impact_db, imp_tag, tau_str);
end


function [ng, nm, nb] = count_verdicts(V)
    ng = 0; nm = 0; nb = 0;
    for k = 1:length(V)
        switch V(k).label
            case 'GOOD',                ng = ng + 1;
            case 'MARG',                nm = nm + 1;
            otherwise,                  nb = nb + 1;   % BAD or SAT
        end
    end
end


function idx_refined = refine_burst_hilbert(idx_imp, env, peak_thresh, off_thresh_base, ...
                                              k_peak_frac, hyst_samp, fallback_samp, ...
                                              peak_search_samp, verbose, channel_label, fs)
% Refine each impact-band burst window using a smoothed Hilbert envelope.
% Inputs:
%   idx_imp          Nx2 impact-band burst windows [start_sample, end_sample]
%   env              full-length envelope vector — abs(hilbert(ch_bp)) low-pass
%                    filtered to remove sample-to-sample jaggedness
%   peak_thresh      if envelope peak inside the peak-search window is below
%                    this, the burst is treated as weak and a fixed-width
%                    fallback window is returned instead (still scored).
%   off_thresh_base  noise-floor-relative threshold (env_med + K_OFF·mad).
%                    Used directly for walk-back (onset detection) so the
%                    rising edge is found near the strike. For walk-forward
%                    (offset), combined with K_PEAK_FRAC per-burst as:
%                    off_thresh_eff = max(off_thresh_base, K_PEAK_FRAC·peak)
%   k_peak_frac      fraction-of-peak floor for offset detection. Handles
%                    strong bursts where pre-strike noise underestimates the
%                    during-session noise floor (structural ringing residual).
%                    For weak bursts, off_thresh_base dominates and behavior
%                    is unchanged.
%   hyst_samp        consecutive samples below off_thresh_eff required to
%                    terminate the forward walk. End-index rewinds to the
%                    start of the sustained-below run.
%   fallback_samp    fallback window width in samples
%   peak_search_samp peak-search window width in samples, measured from
%                    i_imp_s. Real UAE responses peak within ~ms of impact
%                    onset; bounding the search prevents a long stage-2
%                    impact window from picking up the next strike's
%                    backwards-bled energy as the "peak". After the peak
%                    is located, walk-back / walk-forward still operate
%                    over the FULL impact window. If peak_search_samp is
%                    larger than the impact window, the search uses the
%                    whole window (no harm done).
%   verbose          (optional) if true, print per-burst diagnostic trace
%                    showing impact window, peak location/amplitude, fallback
%                    decision, walk-back/forward results, and final window.
%                    Defaults to false.
%   channel_label    (optional) string used in verbose prints, e.g. 'Ch0'.
%                    Defaults to '?'.
%   fs               (optional) sample rate, used to convert sample indices
%                    to seconds in verbose output. Defaults to NaN (then
%                    diagnostic prints sample indices only, no seconds).
%
% Returns Nx2 [start, end] sample indices clamped to the impact window.

    if nargin < 9,  verbose       = false; end
    if nargin < 10, channel_label = '?';   end
    if nargin < 11, fs            = NaN;   end

    if isempty(idx_imp)
        idx_refined = idx_imp;
        return;
    end
    nb = size(idx_imp, 1);
    idx_refined = zeros(nb, 2);

    if verbose
        fprintf('\n  ─── refine_burst_hilbert diagnostic (%s, %d bursts) ───\n', ...
            channel_label, nb);
        fprintf('       peak_thresh = %.4e   off_thresh_base = %.4e   k_peak_frac = %.3f\n', ...
            peak_thresh, off_thresh_base, k_peak_frac);
        fprintf('       hyst_samp = %d   fallback_samp = %d   peak_search_samp = %d\n', ...
            hyst_samp, fallback_samp, peak_search_samp);
    end

    for k = 1:nb
        i_imp_s = idx_imp(k, 1);
        i_imp_e = idx_imp(k, 2);
        % Bound the peak search to the first peak_search_samp of the impact
        % window. Walk-back / walk-forward still use the full window after.
        i_search_e = min(i_imp_e, i_imp_s + peak_search_samp - 1);
        seg = env(i_imp_s:i_search_e);
        [pk, i_pk_rel] = max(seg);
        i_pk = i_imp_s + i_pk_rel - 1;

        if pk < peak_thresh
            % Very weak UAE — fixed-width fallback. Burst still scored.
            idx_refined(k, 1) = i_imp_s;
            idx_refined(k, 2) = min(i_imp_e, i_imp_s + fallback_samp);
            if verbose
                report_diag(k, channel_label, i_imp_s, i_imp_e, i_pk, pk, ...
                    peak_thresh, true, NaN, idx_refined(k,1), idx_refined(k,2), fs);
            end
            continue;
        end

        % Per-burst effective offset threshold: noise-floor OR fraction-of-peak,
        % whichever is higher. Strong bursts (pk >> noise) get peak-relative
        % termination; weak bursts use the noise floor.
        off_thresh_eff = max(off_thresh_base, k_peak_frac * pk);
        % Walk backward from peak to find UAE onset (uses base, not eff,
        % so onset is found near the strike's true rising edge)
        i_uae_s = i_pk;
        while i_uae_s > i_imp_s && env(i_uae_s) > off_thresh_base
            i_uae_s = i_uae_s - 1;
        end
        % Walk forward from peak with hysteresis (uses eff threshold)
        i_uae_e = i_pk;
        below_count = 0;
        below_run_start = i_pk;
        while i_uae_e < i_imp_e
            if env(i_uae_e) < off_thresh_eff
                if below_count == 0
                    below_run_start = i_uae_e;
                end
                below_count = below_count + 1;
                if below_count >= hyst_samp
                    i_uae_e = below_run_start;  % rewind to start of run
                    break;
                end
            else
                below_count = 0;
            end
            i_uae_e = i_uae_e + 1;
        end
        idx_refined(k, 1) = i_uae_s;
        idx_refined(k, 2) = i_uae_e;

        if verbose
            report_diag(k, channel_label, i_imp_s, i_imp_e, i_pk, pk, ...
                peak_thresh, false, off_thresh_eff, i_uae_s, i_uae_e, fs);
        end
    end
end


function report_diag(k, ch, i_imp_s, i_imp_e, i_pk, pk, peak_thresh, ...
                     fb_fired, off_thresh_eff, i_uae_s, i_uae_e, fs)
% Per-burst diagnostic line for refine_burst_hilbert verbose mode.
    if isfinite(fs) && fs > 0
        s2t = @(s) s / fs;  % sample → seconds
        ts_unit = 's';
        imp_s_t = sprintf('%.3f%s', s2t(i_imp_s), ts_unit);
        imp_e_t = sprintf('%.3f%s', s2t(i_imp_e), ts_unit);
        pk_t    = sprintf('%.3f%s', s2t(i_pk),    ts_unit);
        uae_s_t = sprintf('%.3f%s', s2t(i_uae_s), ts_unit);
        uae_e_t = sprintf('%.3f%s', s2t(i_uae_e), ts_unit);
    else
        imp_s_t = sprintf('%d',  i_imp_s);
        imp_e_t = sprintf('%d',  i_imp_e);
        pk_t    = sprintf('%d',  i_pk);
        uae_s_t = sprintf('%d',  i_uae_s);
        uae_e_t = sprintf('%d',  i_uae_e);
    end

    fprintf('       %s burst %d: imp=[%s, %s]  pk=%s (env=%.4e)\n', ...
        ch, k, imp_s_t, imp_e_t, pk_t, pk);
    if fb_fired
        fprintf('         pk < peak_thresh (%.4e) — FALLBACK window\n', peak_thresh);
    else
        fprintf('         pk >= peak_thresh — normal walk  off_thresh_eff=%.4e\n', off_thresh_eff);
    end
    fprintf('         refined: [%s, %s]  width=%.1f ms\n', ...
        uae_s_t, uae_e_t, ...
        ternary(isfinite(fs) && fs > 0, (i_uae_e - i_uae_s) * 1000 / max(fs, eps), NaN));
end


function draw_raw_time_domain(fig, t, ch0_V, ch1_V, idx_ch0_uae, idx_ch1_uae, ...
                              idx_ch0_imp, idx_ch1_imp)
% Two-row plot: raw calibrated voltage (no compensation, no bandpass) with
% both burst-window views overlaid:
%   • light pink = impact-band window (wide; what the detector saw)
%   • green      = UAE-refined window (narrow; what scoring uses)
% This makes the refinement visible at a glance — useful for ML feature
% extraction (impact window) and quality verification (UAE window).
    figure(fig); clf;
    try
        fig.WindowState = 'maximized';
    catch
    end
    tl = tiledlayout(fig, 2, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
    title(tl, ['Raw Time Domain — Calibrated voltage (no compensation, no bandpass)' ...
               '   |   pink = impact-band window, green = UAE-refined window'], ...
          'FontWeight', 'bold');

    ax(1) = nexttile(tl);
    plot(t, ch0_V, 'k', 'LineWidth', 0.4); hold on;
    overlay_bursts(idx_ch0_imp, ch0_V, t, [1.0 0.65 0.65]);   % wide pink
    overlay_bursts(idx_ch0_uae, ch0_V, t, [0.20 0.70 0.20]);  % narrow green
    ylabel('Ch0 raw (V)');
    title(sprintf('Ch0 — %d bursts detected', size(idx_ch0_uae,1)), ...
        'FontWeight','bold','FontSize',10);
    grid on;

    ax(2) = nexttile(tl);
    plot(t, ch1_V, 'k', 'LineWidth', 0.4); hold on;
    overlay_bursts(idx_ch1_imp, ch1_V, t, [1.0 0.65 0.65]);
    overlay_bursts(idx_ch1_uae, ch1_V, t, [0.20 0.70 0.20]);
    ylabel('Ch1 raw (V)'); xlabel('Time (s)');
    title(sprintf('Ch1 — %d bursts detected', size(idx_ch1_uae,1)), ...
        'FontWeight','bold','FontSize',10);
    grid on;

    linkaxes(ax, 'x');
    xlim([t(1), t(end)]);
end


function draw_time_domain(fig, t, ch0_bp, ch1_bp, idx_ch0, idx_ch1, ...
    ste0, ste1, ll0, ll1, thr0, thr1, bp_lo, bp_hi)
% 4-row figure: Ch0 signal (UAE band) + bursts, Ch0 STE+LL (IMPACT band),
%               Ch1 signal (UAE band) + bursts, Ch1 STE+LL (IMPACT band).
% Phase 5+: detection runs on impact band; analysis on UAE band. The plot
% intentionally shows both — the STE/LL traces are how the detector saw
% the signal; the waveform is where downstream UAE scoring happens.
    figure(fig); clf;
    tl = tiledlayout(fig, 4, 1, 'TileSpacing', 'compact', 'Padding', 'compact');
    title(tl, sprintf('Time Domain — Signal: %d–%d kHz UAE band   |   STE/LL: 1–10 kHz impact band (detection)', ...
        round(bp_lo/1e3), round(bp_hi/1e3)), 'FontWeight', 'bold');

    ax(1) = nexttile(tl);
    plot(t, ch0_bp, 'k'); hold on;
    overlay_bursts(idx_ch0, ch0_bp, t, [1 0.4 0.4]);
    ylabel('Ch0  (V)'); title('Ch0 — Compensated, UAE band 20–80 kHz', 'FontWeight','bold','FontSize',10);
    grid on;

    ax(2) = nexttile(tl);
    yyaxis left;  plot(t, ste0, 'b', 'LineWidth', 1.0); ylabel('STE (impact band)');
    yline(thr0.on_ste,  'r--', 'ON');
    yline(thr0.off_ste, 'g--', 'OFF');
    yyaxis right; plot(t, ll0,  'm', 'LineWidth', 1.0); ylabel('LL (impact band)');
    yline(thr0.on_ll,  'r:');
    yline(thr0.off_ll, 'g:');
    title('Ch0 — STE (left) + LL (right) on 1–10 kHz impact band', 'FontWeight','bold','FontSize',10);
    grid on;

    ax(3) = nexttile(tl);
    plot(t, ch1_bp, 'k'); hold on;
    overlay_bursts(idx_ch1, ch1_bp, t, [1 0.4 0.4]);
    ylabel('Ch1  (V)'); title('Ch1 — Compensated, UAE band 20–80 kHz', 'FontWeight','bold','FontSize',10);
    grid on;

    ax(4) = nexttile(tl);
    yyaxis left;  plot(t, ste1, 'b', 'LineWidth', 1.0); ylabel('STE (impact band)');
    yline(thr1.on_ste,  'r--');
    yline(thr1.off_ste, 'g--');
    yyaxis right; plot(t, ll1,  'm', 'LineWidth', 1.0); ylabel('LL (impact band)');
    yline(thr1.on_ll,  'r:');
    yline(thr1.off_ll, 'g:');
    title('Ch1 — STE (left) + LL (right) on 1–10 kHz impact band', 'FontWeight','bold','FontSize',10);
    xlabel('Time  (s)'); grid on;

    linkaxes(ax, 'x');
    xlim([t(1), t(end)]);
end


function overlay_bursts(idx, sig, t, color)
    if isempty(idx), return; end
    yl = [min(sig), max(sig)];
    if yl(1) == yl(2), yl = yl + [-1 1]; end
    for k = 1:size(idx, 1)
        i1 = idx(k, 1); i2 = idx(k, 2);
        patch([t(i1) t(i2) t(i2) t(i1)], [yl(1) yl(1) yl(2) yl(2)], ...
            color, 'FaceAlpha', 0.18, 'EdgeColor', 'none');
    end
end


function draw_zoomed_starts(fig, t, ch0_bp, ch1_bp, idx_ch0, idx_ch1, fs)
% Two rows × N_max cols: zoomed view ~5 ms around each burst onset.
    n0 = size(idx_ch0, 1);
    n1 = size(idx_ch1, 1);
    n_max = max(n0, n1);
    if n_max == 0
        figure(fig); clf;
        annotation(fig, 'textbox', [0 0.4 1 0.2], 'String', 'No bursts detected', ...
            'HorizontalAlignment', 'center', 'FontSize', 14, ...
            'FontWeight', 'bold', 'EdgeColor', 'none');
        return;
    end

    figure(fig); clf;
    tl = tiledlayout(fig, 2, n_max, 'TileSpacing', 'compact', 'Padding', 'compact');
    title(tl, 'Zoomed Burst Onsets (±2 ms)', 'FontWeight', 'bold');

    pre_s  = 0.0005;
    post_s = 0.005;

    for k = 1:n_max
        % Ch0 row
        nexttile(tl, k);
        if k <= n0
            i1 = idx_ch0(k, 1);
            t1 = max(t(1),    t(i1) - pre_s);
            t2 = min(t(end),  t(i1) + post_s);
            mask = (t >= t1) & (t <= t2);
            plot(t(mask) * 1e3, ch0_bp(mask), 'k'); hold on;
            xline(t(i1) * 1e3, 'r--', 'onset');
            grid on;
            title(sprintf('Ch0 Strike %d', k), 'FontSize', 9);
        else
            text(0.5, 0.5, '—', 'Units','normalized', ...
                 'HorizontalAlignment', 'center', 'FontSize', 16);
            axis off;
        end
        if k == 1, ylabel('Ch0 (V)'); end

        % Ch1 row
        nexttile(tl, n_max + k);
        if k <= n1
            i1 = idx_ch1(k, 1);
            t1 = max(t(1),   t(i1) - pre_s);
            t2 = min(t(end), t(i1) + post_s);
            mask = (t >= t1) & (t <= t2);
            plot(t(mask) * 1e3, ch1_bp(mask), 'k'); hold on;
            xline(t(i1) * 1e3, 'r--');
            grid on;
            title(sprintf('Ch1 Strike %d', k), 'FontSize', 9);
        else
            text(0.5, 0.5, '—', 'Units','normalized', ...
                 'HorizontalAlignment', 'center', 'FontSize', 16);
            axis off;
        end
        if k == 1, ylabel('Ch1 (V)'); end
        xlabel('Time (ms)');
    end
end


function append_field_log(log_path, load_name, n0, n1, n_exp, ...
    M0, M1, V0, V1, decision, note_text, fs)
% Append one row to field_log.csv, creating with header if it doesn't exist.
    ts_abs = datestr(now, 'yyyy-mm-dd HH:MM:SS');

    % Helper: build per-strike block (verdict, snr, r2, psdcorr, sat, impact, t_rel_s)
    % for up to N_STRIKES_EXPECTED strikes per channel.
    n_max = max([n_exp, n0, n1]);

    headers = {'timestamp','filename','ch0_burst_count','ch1_burst_count','expected_count'};
    for ch = 0:1
        for s = 1:n_max
            prefix = sprintf('ch%d_s%d', ch, s);
            headers = [headers, ...
                {[prefix '_verdict'], [prefix '_snr_db'], [prefix '_r2'], ...
                 [prefix '_psdcorr'], [prefix '_saturated'], ...
                 [prefix '_impact_db'], [prefix '_t_rel_s']}];
        end
    end
    headers = [headers, {'decision','note'}];

    % Build row values
    row = {ts_abs, load_name, n0, n1, n_exp};
    for ch = 0:1
        if ch == 0, M = M0; V = V0; else, M = M1; V = V1; end
        for s = 1:n_max
            if s <= length(M)
                t_rel = M(s).idx(1) / fs;
                row = [row, {V(s).label, ...
                    sprintf('%.2f', M(s).snr_db), ...
                    sprintf('%.4f', M(s).decay_r2), ...
                    sprintf('%.4f', M(s).psd_corr), ...
                    ternary(M(s).saturated, 'Y', 'N'), ...
                    sprintf('%.2f', M(s).impact_db), ...
                    sprintf('%.4f', t_rel)}];
            else
                row = [row, {'MISSING','','','','','',''}];
            end
        end
    end
    row = [row, {decision, note_text}];

    % Write
    write_header = ~isfile(log_path);
    fid = fopen(log_path, 'a');
    if fid < 0
        warning('Could not open log file: %s', log_path);
        return;
    end
    if write_header
        fprintf(fid, '%s\n', strjoin(headers, ','));
    end
    fprintf(fid, '%s\n', strjoin(cellfun(@csv_safe, row, 'UniformOutput', false), ','));
    fclose(fid);
end


function s = csv_safe(x)
    if isnumeric(x)
        s = num2str(x);
    else
        s = char(x);
    end
    if any(s == ',') || any(s == '"') || any(s == newline)
        s = ['"', strrep(s, '"', '""'), '"'];
    end
end


function out = ternary(cond, a, b)
    if cond, out = a; else, out = b; end
end

function m = mad1(x)
% Median Absolute Deviation about the median - base-MATLAB implementation
% equivalent to mad(x, 1) from the Statistics & Machine Learning Toolbox.
% Stats Toolbox is not assumed in this script.
    x = x(:);
    m = median(abs(x - median(x)));
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

% ═════════════════════════════════════════════════════════════════════
%                     BATCH-MODE HELPER FUNCTIONS 
% ═════════════════════════════════════════════════════════════════════

function T = make_empty_manifest()
% Empty manifest table with the canonical column types.
% Columns: basename, burst_path, decision, n_strikes_ch0, n_strikes_ch1,
%          expected_strikes, timestamp, script_version
    T = table( ...
        strings(0,1), strings(0,1), strings(0,1), ...
        zeros(0,1,'uint8'), zeros(0,1,'uint8'), zeros(0,1,'uint8'), ...
        NaT(0,1), strings(0,1), ...
        'VariableNames', {'basename', 'burst_path', 'decision', ...
                          'n_strikes_ch0', 'n_strikes_ch1', ...
                          'expected_strikes', 'timestamp', 'script_version'});
end


function row = make_manifest_row(basename, burst_path, decision, ...
    n0, n1, n_exp, script_version)
% Single-row table matching the schema in make_empty_manifest.
    row = table( ...
        string(basename), string(burst_path), string(decision), ...
        uint8(n0), uint8(n1), uint8(n_exp), ...
        datetime('now'), string(script_version), ...
        'VariableNames', {'basename', 'burst_path', 'decision', ...
                          'n_strikes_ch0', 'n_strikes_ch1', ...
                          'expected_strikes', 'timestamp', 'script_version'});
end


function save_burst_data(burst_path, basename, source_file, source_path, ...
    fs, n_samples, script_version, decision, note_text, ...
    expected_strikes, n_strikes_ch0, n_strikes_ch1, ...
    idx_ch0_uae, idx_ch1_uae, idx_ch0_imp, idx_ch1_imp, ...
    ch0_comp, ch1_comp, ch0_bp, ch1_bp)
% Write per-capture burst-clip file. Schema (see consolidator script):
%
%   burst_data.meta            — {basename, specimen_id, measurement_point, source_file,
%                                 source_path, fs, n_samples, duration_s,
%                                 timestamp, script_version,
%                                 expected_strikes, n_strikes_ch0/1}
%   burst_data.decision        — 'KEEP' or 'KEEP_NOTE'
%   burst_data.note_text       — '' or user-entered string
%   burst_data.windows         — Nx2 indices, both UAE-refined and impact-band,
%                                 for both channels
%   burst_data.ch0/.ch1
%       .raw{i}                — ch{0,1}_comp over idx_imp(i,:)   (post-comp,
%                                 pre-BP; broad impact-band window, ~1–5 s)
%       .uae{i}                — ch{0,1}_bp  over idx_uae(i,:)    (post-comp,
%                                 post-BP; narrow UAE window, ~0.1–0.7 s)
%       .t_raw{i}              — time vector for raw{i}, seconds from capture start
%       .t_uae{i}              — time vector for uae{i}, seconds from capture start
%
% Both signals stored as double, full sample rate. Per-strike clips only —
% no full-capture signals saved (would multiply file size by ~30×).

    % ─── meta ──────────────────────────────────────────────────────────
    [specimen_id, measurement_point] = parse_basename(basename);

    meta.basename         = basename;
    meta.specimen_id      = specimen_id;
    meta.measurement_point = measurement_point;
    meta.source_file      = source_file;
    meta.source_path      = source_path;
    meta.fs               = fs;
    meta.n_samples        = uint32(n_samples);
    meta.duration_s       = double(n_samples) / fs;
    meta.timestamp        = datetime('now');
    meta.script_version   = script_version;
    meta.expected_strikes = uint8(expected_strikes);
    meta.n_strikes_ch0    = uint8(n_strikes_ch0);
    meta.n_strikes_ch1    = uint8(n_strikes_ch1);

    % ─── windows ───────────────────────────────────────────────────────
    windows.idx_ch0_uae = int32(idx_ch0_uae);
    windows.idx_ch1_uae = int32(idx_ch1_uae);
    windows.idx_ch0_imp = int32(idx_ch0_imp);
    windows.idx_ch1_imp = int32(idx_ch1_imp);

    % ─── per-strike clips ──────────────────────────────────────────────
    ch0 = extract_clips(ch0_comp, ch0_bp, idx_ch0_imp, idx_ch0_uae, fs);
    ch1 = extract_clips(ch1_comp, ch1_bp, idx_ch1_imp, idx_ch1_uae, fs);

    % ─── assemble + save ───────────────────────────────────────────────
    burst_data.meta      = meta;
    burst_data.decision  = decision;
    burst_data.note_text = note_text;
    burst_data.windows   = windows;
    burst_data.ch0       = ch0;
    burst_data.ch1       = ch1;

    save(burst_path, 'burst_data', '-v7.3');
end


function clips = extract_clips(sig_comp, sig_bp, idx_imp, idx_uae, fs)
% Extract per-strike clips for one channel.
% raw{i}  = sig_comp over idx_imp(i,:)  (broad impact-band window)
% uae{i}  = sig_bp   over idx_uae(i,:)  (narrow UAE-refined window)
% t_raw{i}, t_uae{i} are time vectors in seconds from capture start.
    n_imp = size(idx_imp, 1);
    n_uae = size(idx_uae, 1);

    % UAE refinement may emit fewer windows than impact detection if a
    % weak burst's fallback returned a degenerate window. Use min for safety.
    n_strikes = min(n_imp, n_uae);

    raw   = cell(1, n_strikes);
    uae   = cell(1, n_strikes);
    t_raw = cell(1, n_strikes);
    t_uae = cell(1, n_strikes);

    for k = 1:n_strikes
        s_imp = idx_imp(k, 1); e_imp = idx_imp(k, 2);
        s_uae = idx_uae(k, 1); e_uae = idx_uae(k, 2);

        raw{k}   = sig_comp(s_imp:e_imp);
        uae{k}   = sig_bp(s_uae:e_uae);
        t_raw{k} = (s_imp-1 : e_imp-1)' / fs;
        t_uae{k} = (s_uae-1 : e_uae-1)' / fs;
    end

    clips.raw   = raw;
    clips.uae   = uae;
    clips.t_raw = t_raw;
    clips.t_uae = t_uae;
end


function [specimen_id, measurement_point] = parse_basename(basename)
% Parse 'Specimen_<N>_<POINT>' → (N, 'POINT').  POINT is 'P1', 'P2', etc.
% Returns specimen_id = NaN, measurement_point = '' on parse failure (defensive).
    specimen_id = NaN;
    measurement_point = '';
    tok = regexp(basename, '^Specimen_(\d+)_(P\d+)$', 'tokens', 'once');
    if ~isempty(tok)
        specimen_id = str2double(tok{1});
        measurement_point = tok{2};
    end
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
