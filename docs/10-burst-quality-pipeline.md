# Burst-quality pipeline

The burst-quality pipeline determines whether hammer strikes recorded during a field measurement are suitable for later analysis.

It detects each strike independently on both channels, identifies the useful ultrasonic-acoustic-emission window, calculates physical and statistical quality metrics, and assigns one of four results:

- **GOOD**
- **MARGINAL**
- **BAD**
- **SATURATED**

The operator then decides whether to keep the capture, keep it with a note, or skip it.

Two MATLAB scripts implement the pipeline:

| Script | Purpose |
|---|---|
| [`scripts/characterize_noise_baseline.m`](../scripts/characterize_noise_baseline.m) | Measures the site-specific ambient-noise reference |
| [`scripts/daq_burst_quality.m`](../scripts/daq_burst_quality.m) | Detects bursts, calculates metrics, assigns verdicts, and saves selected burst files |

The scripts require MATLAB with the Signal Processing Toolbox.

## Why strike quality is checked

A field capture may contain the expected number of hammer strikes without every strike being usable.

Examples include a glancing, double, or weak strike; poor sensor coupling; cable motion; clipping; an incorrect measurement point; an unrelated transient; or a spectral shape that differs from the other strikes.

The most expensive failure is discovering an unusable strike after leaving the measurement site.

The pipeline therefore provides a near-real-time decision:

**capture completed**  
→ **bursts detected**  
→ **windows refined**  
→ **quality metrics calculated**  
→ **verdicts displayed**  
→ **operator keeps, annotates, skips, or repeats the measurement**

## Processing overview

The main processing path is:

1. Load raw Channel 0 and Channel 1 analog-to-digital converter (ADC) counts.
2. Apply the per-capture calibration and convert counts to voltage.
3. Check raw counts for saturation.
4. Apply Method B compensation and create both analysis bands.
5. Load the site baseline or use the configured fallback segment.
6. Detect events independently on each channel.
7. Extend and refine the burst windows.
8. Calculate metrics, apply hard gates, and assign verdicts.
9. Display the diagnostic figures for operator review.
10. Save accepted burst clips and update the campaign record.

## Two frequency bands

The pipeline separates event detection from event quality analysis.

### Impact band: 1 to 10 kHz

The impact band contains low-frequency structural response from the hammer strike.

It is used for:

- initial burst detection
- the impact-strength metric
- wide event-window definition

The project measurements indicated that approximately 40% of strike energy appeared in this band, compared with approximately 3% in the ultrasonic band. Impact-band triggering therefore remains reliable when high-frequency sensor coupling is weak.

### Ultrasonic-acoustic-emission analysis band: 20 to 80 kHz

The ultrasonic-acoustic-emission (UAE) band is used for:

- burst signal-to-noise ratio (SNR)
- decay fitting
- ring-down time constant
- power-spectral-density comparison
- final quality scoring

Both bands use fourth-order Butterworth band-pass filters applied with zero-phase `filtfilt` processing.

## Stage 1: record a site noise baseline

Detection thresholds should not be treated as fixed voltage levels because the ambient noise changes with:

- measurement site
- sensor installation
- specimen
- cable routing
- nearby equipment
- grounding
- time and temperature

A dedicated baseline is recorded once per site or session.

### Baseline recording procedure

1. Install the sensors and preamplifiers in the normal measurement arrangement.
2. Power all equipment normally.
3. Do not apply hammer strikes.
4. Record approximately 10 seconds using `start_daq_uae.py`.
5. Store the file in the configured data directory.
6. Set `USER_FILE` in `characterize_noise_baseline.m`, or select the latest-file load mode.
7. Run `characterize_noise_baseline.m`.
8. Inspect the diagnostic figure.
9. Repeat the recording if a tap, cable movement, or strong interference event is visible.
10. Confirm that `noise_baseline.mat` was saved.

### Baseline preprocessing

The baseline script:

1. loads the raw `int32` counts
2. uses the calibration stored in the capture when available
3. falls back to the frozen calibration constants for an older file
4. applies the same Method B compensation used by the field-quality script
5. creates the 20 to 80 kHz and 1 to 10 kHz signals
6. calculates separate statistics for Channel 0 and Channel 1

Using the same calibration and compensation method keeps the baseline and later strike captures on the same processing basis.

## Baseline transient check

The baseline should contain ambient noise rather than an impact event.

The script calculates a 100 ms rolling root mean square (RMS) level. A warning is issued if any rolling window exceeds the median rolling RMS by more than 20 decibels (dB).

The warning does not automatically stop the script. The operator must inspect the diagnostic figure and decide whether the baseline should be recorded again.

This is important because robust statistics resist isolated outliers, but they are not immune to sustained disturbance.

## Baseline statistics

The script calculates:

- RMS noise in the 20 to 80 kHz UAE band
- RMS noise in the 1 to 10 kHz impact band
- short-time energy statistics in both bands
- line-length statistics in both bands

Short-time energy (STE) represents the local signal amplitude over a moving window.

Line length (LL) measures the accumulated absolute sample-to-sample change:

```text
LL = sum(|x[n] - x[n-1]|)
```

It responds to changes in waveform activity that may not be represented by energy alone.

For both STE and LL, the baseline stores:

- median
- `1.4826 × MAD`
- 99th percentile

`MAD` is the median absolute deviation:

```text
MAD = median(|x - median(x)|)
```

The factor `1.4826` converts the MAD into a standard-deviation-equivalent scale for approximately Gaussian noise.

Median and MAD are used because a single electrical spike or cable disturbance has less effect on them than on the mean and conventional standard deviation.

## Saved noise-baseline file

The script saves `noise_baseline.mat` in the configured data directory.

The file records the source capture, timestamp, sample rate, duration, sample count, both frequency bands, detector-window size, per-channel RMS references, STE and LL statistics, and transient-check results.

The burst-quality script loads this file automatically if it exists and its sample rate matches the capture.

If the file is missing, incompatible, or lacks the newer impact-band fields, the current configuration falls back to statistics from the first 0.25 seconds of the capture.

A dedicated baseline is preferred because the beginning of a measurement file is not guaranteed to be quiet.

## Main burst-quality script

The main script supports two run modes.

### Single-file mode

Set:

```matlab
BATCH_MODE = false;
```

Single-file mode processes either the most recently modified matching capture or the file named by `USER_FILE`. It is intended for investigating, tuning, or reprocessing one capture while reviewing the complete diagnostics.

With `BURST_SAVE_IN_SINGLE_MODE = true`, an accepted result also writes the burst file and updates the manifest.

Single-file mode appends the operator decision and metrics to `field_log.csv`.

### Batch mode

Set:

```matlab
BATCH_MODE = true;
```

Batch mode generates filenames from selected specimen identifiers and measurement points `P1` through `P6`, using the pattern `Specimen_<N>_<P>.mat`.

The script supports two configured campaign groups:

- `SET_A`: specimens 1 through 11
- `SET_B`: specimens 12 through 22

It loads `processed.mat` from the burst-output directory and skips files already present in the manifest unless:

```matlab
FORCE_REPROCESS = true;
```

Missing input files are reported and skipped.

## Loading and calibration

Each capture must contain:

```text
ch0_raw
ch1_raw
sample_rate
```

The script prefers the calibration values stored in the capture:

```text
gain_ch0
offset_ch0
gain_ch1
offset_ch1
```

Frozen fallback values are used only for older captures without calibration metadata. A warning is produced when fallback values are required or when stored values differ from the frozen defaults. The conversion is:

```text
voltage = raw count × gain + offset
```

## Saturation check

Saturation is checked on the raw ADC counts before compensation and band-pass filtering.

The AD4630-24 produces a signed 24-bit value with a nominal magnitude limit of `2^23`.

The implemented saturation threshold is:

```text
SAT_LIMIT = 0.95 × 2^23
```

If any raw sample inside a burst window reaches or exceeds this magnitude, the burst receives the SATURATED result.

Saturation overrides the derived metrics because clipping changes the waveform before later processing.

## Method B compensation

The script applies the validated Method B Wiener compensation independently to both channels.

The same frequency points, channel gain arrays, extrapolation cutoffs, and regularization constants are used by:

- normal Python capture quick-look processing
- noise-baseline characterization
- burst-quality analysis

The compensation method is described in [07, digital compensation](07-digital-compensation.md).

## Burst detection stages

The pipeline uses multiple stages because one window is not ideal for both reliable impact detection and ultrasonic scoring.

### Stage 1: impact-band detection

Bursts are detected independently on Channel 0 and Channel 1 using the 1 to 10 kHz impact-band signal.

The detector calculates:

- STE contour
- LL contour

The configured detector uses:

| Parameter | Value |
|---|---:|
| STE and LL window | 200 µs |
| ON threshold multiplier | 12 |
| OFF threshold multiplier | 6 |
| Minimum lockout between detected bursts | 0.2 s |
| Peak STE floor | 100 × noise median |

The ON and OFF levels are based on:

```text
threshold = median + multiplier × (1.4826 × MAD)
```

The peak floor rejects a candidate whose maximum STE is too close to the noise background.

### Stage 2: extend the impact window

The first detector can end a window too early if STE or LL briefly falls below the OFF threshold during ring-down.

The window end is extended until both contours remain below their OFF levels for 50 ms.

For all except the final burst, the extension is limited to:

```text
next strike start - 0.10 s
```

This prevents one window from absorbing the next impact.

### Stage 2.5: retain the strongest expected bursts

The current configuration expects three hammer strikes per capture:

```matlab
N_STRIKES_EXPECTED = 3;
MAX_BURSTS_CAP_GLOBAL = 3;
```

If more than three candidates are detected on a channel, the script keeps the three with the highest impact-band peak STE. Their chronological order is restored before later processing.

This stage assumes that the field procedure actually contained three real strikes. A missed strike combined with a false detection could still cause the wrong candidate to be retained. The operator must therefore review the plots and strike count.

### Stage 3: refine the UAE window

Impact-band structural ring-down may last approximately 1 to 5 seconds. Using the entire impact window for ultrasonic scoring would include long periods of post-event noise and reduce the calculated SNR.

The script therefore finds a narrower window inside each impact window using the 20 to 80 kHz UAE signal.

The refinement uses:

1. the absolute Hilbert-transform envelope
2. a 200 Hz low-pass filter to smooth the envelope
3. a local noise estimate from the start of the capture
4. a peak search limited to the first 0.30 seconds after the impact-window start
5. backward and forward threshold searches around the selected peak
6. 15 ms of below-threshold hysteresis for the window end
7. a 0.20-second fallback window for a weak UAE burst

The forward threshold includes both:

- a noise-relative level
- 3% of the individual burst peak, equivalent to approximately minus 30 dB

The larger threshold is used. This prevents a strong burst from producing an excessively long refined window when the pre-strike noise estimate is unusually low.

The original wide impact window is retained for debugging and feature extraction. Final quality metrics use the narrower UAE-refined window.

### Stage 4: add head and tail margins

After refinement, the script adds:

- 1 ms before the detected onset
- 20 ms after the detected end

These margins preserve nearby waveform context without returning to the full impact-band window.

## Noise drift check

When `noise_baseline.mat` is loaded, the script compares the current capture's UAE-band median STE with the stored baseline.

A warning is issued when either channel changes by more than:

```text
±6 dB
```

A drift warning can indicate:

- changed sensor coupling
- different cable routing
- increased site interference
- changed grounding
- a stale baseline

The script recommends repeating the baseline characterization when the shift is excessive.

## Per-burst quality metrics

Each refined burst receives the following metrics.

### 1. Signal-to-noise ratio

Signal-to-noise ratio (SNR) compares the burst RMS voltage with the baseline UAE-band RMS voltage:

```text
SNR_dB = 20 log10(burst_RMS / noise_RMS)
```

### 2. Decay coefficient of determination

The script calculates the Hilbert envelope of the burst, smooths it, and fits:

```text
log(envelope) = log(A) - t / τ
```

The fit starts at the envelope peak and extends down to:

```text
peak - 25 dB
```

The coefficient of determination, `R^2`, measures how closely the weighted log-domain decay follows the fitted exponential.

A clean single ring-down should generally produce a higher `R^2` than a double strike, disturbed decay, or irregular event.

### 3. Ring-down time constant

The ring-down time constant `τ` is calculated from the fitted negative slope:

```text
τ = -1 / slope
```

It is reported in milliseconds.

A non-decaying or rising fit produces an invalid time constant.

### 4. Power-spectral-density correlation

Power spectral density (PSD) is estimated for every burst over the 20 to 80 kHz band.

The script compares the spectral shapes in decibels using Pearson correlation.

The reference is not automatically the loudest strike. The current implementation selects the burst with the highest mean pairwise PSD correlation to the other bursts. This chooses the most representative spectral shape and reduces the chance that one loud outlier becomes the template.

The reference burst's own PSD correlation is stored as not-a-number (`NaN`) because self-correlation is not informative. Verdict logic treats this value as passing the PSD-correlation condition and judges that burst using the remaining metrics.

### 5. Impact strength

Impact strength compares 1 to 10 kHz burst RMS with the impact-band baseline RMS:

```text
Impact_dB = 20 log10(burst_RMS_1-10kHz / noise_RMS_1-10kHz)
```

This verifies that the event contains a real low-frequency structural excitation.

## Hard physical gates

Two gates are applied before GOOD or MARGINAL classification.

### Impact gate

```text
Impact_dB >= 15 dB
```

### Ring-down-time gate

```text
2 ms <= τ <= 50 ms
```

If either gate fails, the burst is BAD regardless of SNR, `R^2`, or PSD correlation.

These gates reject events that do not behave like a plausible structural hammer-strike ring-down.

## Verdict thresholds

After the hard gates pass, the verdict is:

| Verdict | Requirements |
|---|---|
| GOOD | `SNR >= 35 dB`, `R^2 >= 0.95`, and `PSD correlation >= 0.80` |
| MARGINAL | `SNR >= 25 dB`, `R^2 >= 0.85`, and `PSD correlation >= 0.60`, but not GOOD |
| BAD | Below the MARGINAL thresholds or failed hard gate |
| SATURATED | Any raw sample in the burst window reaches `0.95 × 2^23` |

Saturation takes priority over the other verdicts.

## Diagnostic figures

The script displays four figures.

### 1. Verdict dashboard

The dashboard shows the detected and expected counts, verdicts, SNR, decay `R^2`, PSD correlation, impact level, ring-down time constant, and any saturation or low-impact warnings.

### 2. Full time-domain and detector contours

This figure shows the compensated 20 to 80 kHz signals, detected windows, impact-band STE and LL contours, and detector thresholds.

### 3. Zoomed burst starts

This figure provides a short view around every detected onset for both channels.

It helps identify double strikes, timing differences, incorrect onset placement, and missing channel responses.

### 4. Raw time-domain view

This figure shows calibrated voltage without compensation or band-pass filtering.

It overlays:

- the wide impact-band windows
- the narrower UAE-refined windows

This makes the window-refinement decision visible and retains a reference view of the less-processed waveform.

## Operator decision

After reviewing the figures, the operator selects:

| Input | Action |
|---|---|
| Enter or `k` | Keep and save |
| `n` | Keep, save, and enter a note |
| `s` | Skip without a burst file or manifest entry |

An unrecognized input defaults to KEEP.

Skipping a file in single-file mode still records the decision in `field_log.csv`, but it does not write a burst file or update the manifest.

## Saved burst file

Accepted captures are saved as:

```text
Specimen_<N>_<P>_bursts.mat
```

The saved `burst_data` structure includes:

- source filename and source path
- specimen identifier
- measurement point
- sample rate and duration
- script version
- operator decision and note
- expected and detected strike counts
- wide impact windows
- narrow UAE windows
- per-channel compensated wide-window clips
- per-channel band-passed UAE clips

The original capture remains unchanged and continues to contain the raw ADC counts and acquisition metadata.

## Manifest and comma-separated-values records

### Batch manifest

Batch mode uses:

```text
processed.mat
```

The manifest records:

- capture basename
- saved burst-file path
- operator decision
- Channel 0 and Channel 1 strike counts
- expected strike count
- processing timestamp
- script version

The manifest is updated by capture basename. Reprocessing an existing capture replaces its row instead of adding a duplicate.

### Single-file comma-separated-values (CSV) log

Single-file mode appends to:

```text
field_log.csv
```

The log includes the timestamp, filename, detected and expected counts, per-strike metrics and verdicts, saturation indicators, relative strike times, operator decision, and note.

## Consistency requirements

The following items must remain consistent between the baseline and quality scripts:

- calibration behavior
- Method B compensation constants
- channel system-identification arrays
- 20 to 80 kHz UAE band
- 1 to 10 kHz impact band
- STE and LL window definition

If these differ, the baseline thresholds no longer describe the processed strike signals correctly.

## Pipeline summary

1. A dedicated quiet capture establishes the site and session noise conditions.
2. Median, scaled MAD, and percentile statistics reduce the influence of isolated outliers.
3. Impact-band detection, window extension, and strongest-three selection follow the field strike protocol.
4. UAE-envelope refinement identifies the shorter window used for scoring.
5. SNR, decay behavior, PSD similarity, and impact strength measure different aspects of quality.
6. Hard physical gates are applied before grading, and raw-count saturation overrides derived metrics.
7. The operator makes the final keep, annotate, or skip decision after reviewing four figures.
8. Burst files, the manifest, and the CSV log preserve the decision and campaign history.
