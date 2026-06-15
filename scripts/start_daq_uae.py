"""
start_daq_uae.py — Dual-channel DAQ acquisition with Method B Wiener compensation

Signal chain:
  UAE sensor (broadband ultrasonic acoustic-emission) + preamp → ADA4945-1 FDA (AFE) → AD4630-24 ADC
    → ZedBoard DMA → Gigabit Ethernet → this script

Workflow:
  Capture is run locally on the ZedBoard (iio_readdev into /tmp), pulled over
  SFTP, parsed, calibrated, and compensated here for a fast quality glance.
  The saved .mat stores ONLY the raw int32 counts plus full metadata — all
  calibrated/compensated signals are recomputable downstream in MATLAB from
  raw + metadata, so the capture file is a single reproducible source of truth.

Compensation:
  Method B — Non-parametric Wiener deconvolution with cepstral minimum-phase
    |H_AFE(f)|: PCHIP-interpolated from 24-point single-channel sysid
    φ(f):       Hilbert-derived minimum-phase via real cepstrum
    ε(f):       Frequency-dependent regularization (tanh rolloff above 135 kHz)
    G(f) = H_AFE*(f) / (|H_AFE(f)|² + ε(f))

  Each channel has its own compensator built from independent sysid data.

  Implementation: single rfft over entire capture → multiply by compensator
  built on the signal's native frequency grid → irfft back. No blocking,
  no overlap-save, no interpolation of the compensator. Mathematically
  identical to MATLAB's fft/ifft approach.
"""

import numpy as np
import paramiko
import time
from scipy.io import savemat
from scipy.interpolate import PchipInterpolator
from scipy import signal as sig
import os
import sys
import tempfile
import matplotlib.pyplot as plt

from acquisition_io import (
    AcquisitionError,
    cleanup_capture_resources,
    ensure_output_directory,
    parse_binary_dual,
    pull_capture,
    run_remote_capture,
)

# ╔===================================================================╗
# ║  USER CONFIG — edit these for your setup                          ║
# ╚===================================================================╝

# -- Hardware / Network --------------------------------------
ZED_IP   = "192.168.1.100"     # ZedBoard static IP (set via UART — see docs/03)
ZED_USER = "root"
ZED_PASS = os.environ.get("ZED_PASS", "analog")   # from env var ZED_PASS; falls back to the stock ADI Kuiper default

# -- ADC Calibration (per channel; from the per-channel multi-point method (calibrate_dual.py), docs/05) --
GAIN_CH0   = 0.0000006268      # V/count
OFFSET_CH0 = -0.040402         # V
GAIN_CH1   = 0.0000006355
OFFSET_CH1 = 0.000751

FS = 500000          # 500 kSPS nominal (measured: 500003.84 Hz, +7.7 ppm)

# -- Capture Settings ----------------------------------------
CAPTURE_SECONDS = 10
TOTAL_SAMPLES   = CAPTURE_SECONDS * FS
IIO_BUFFER_SIZE = 200000
REMOTE_BIN      = "/tmp/capture.bin"
CAPTURE_TIMEOUT_MARGIN_S = 15

# -- Save Directory (host) -----------------------------------
SAVE_DIR = r"E:\DAQ Data\Data_files"

# ============================================================
#  AFE COMPENSATION — Method B (Cepstral Min-Phase Wiener)
# ============================================================
#
# ROOT CAUSE: ADA4945-1 FDA feedback network (C18/C24 2700 pF + R16/R26 1kΩ)
#   creates 1st-order LP rolloff ~48 kHz (wiring-dependent), with
#   non-monotonic features at 30–42 kHz plateau and 90–100 kHz dip.
#
# Each channel has independent sysid magnitude data from single-channel
# swept-sine calibration (freq_sweep_sysid_dual.py → sysid_analysis_dual.m).
#
# Phase is derived via cepstral method (Hilbert transform of log-magnitude)
# — validated to sub-1° accuracy against hardware measurements.

# -- Compensator Design Parameters ---------------------------
EPS_FLOOR = 1e-4          # regularization floor (keeps inverse stable)
EPS_WALL  = 50            # regularization wall (kills signal above f_edge)
F_EDGE    = 135000        # Hz — rolloff center
DF_TRANS  = 3000          # Hz — transition half-width

# -- Sysid Data: 24-point single-channel measurements --------
# Source: freq_sweep_sysid_dual.py → sysid_analysis_dual.m → sysid_final_results.mat
SYSID_FREQS = np.array([
    1000, 5000, 10000, 15000, 20000, 25000,
    30000, 33000, 36000, 39000, 42000, 45000,
    50000, 53000, 60000, 65000, 70000, 75000,
    85000, 90000, 95000, 100000, 110000, 120000,
], dtype=np.float64)

# |H(f)| = measured_amplitude / input_vpeak, single-channel, 3-repeat averaged
SYSID_GAIN_CH0 = np.array([
    0.9997, 0.9924, 0.9691, 0.9321, 0.8835, 0.8255,
    0.7614, 0.7423, 0.7459, 0.7463, 0.7440, 0.7389,
    0.7246, 0.7126, 0.6772, 0.6461, 0.6113, 0.5735,
    0.4925, 0.4501, 0.4242, 0.4264, 0.4180, 0.3960,
], dtype=np.float64)

SYSID_GAIN_CH1 = np.array([
    0.9984, 0.9909, 0.9667, 0.9285, 0.8780, 0.8186,
    0.7522, 0.7539, 0.7576, 0.7573, 0.7544, 0.7483,
    0.7321, 0.7191, 0.6805, 0.6469, 0.6094, 0.5688,
    0.4831, 0.4406, 0.4394, 0.4389, 0.4262, 0.4001,
], dtype=np.float64)

# 1-pole fc for extrapolation above 120 kHz
FC_CH0 = 48149.0   # Hz
FC_CH1 = 48674.0   # Hz

# -- Visualization Settings ----------------------------------
ZOOM_MS      = 0.5
FFT_WINDOW   = 'hann'
MAX_PLOT_PTS = 50000
WELCH_TARGET_AVG = 200   # adaptive NFFT target (~averages with 50% overlap)


# ============================================================
#  COMPENSATION — Single-FFT approach
# ============================================================

def _build_magnitude_on_grid(f, sysid_freqs, sysid_gain, fc_1p):
    """Interpolate measured |H_AFE| onto an arbitrary frequency grid.

    Args:
        f:            frequency vector (Hz), e.g. from rfftfreq. Shape (M,).
        sysid_freqs:  measured frequency points (Hz). Shape (K,).
        sysid_gain:   measured gain ratio at those points. Shape (K,).
        fc_1p:        1-pole cutoff (Hz) for extrapolation above max sysid freq.

    Returns:
        mag: |H_AFE(f)| on the grid. Shape (M,).

    Regions:
        f = 0:                   1.0 (DC)
        0 < f < sysid_freqs[0]:  1.0 (flat passband)
        sysid_freqs[0] <= f <= sysid_freqs[-1]: PCHIP in log domain
        f > sysid_freqs[-1]:     1-pole extrapolation anchored at last sysid point
    """
    M = len(f)
    mag = np.ones(M, dtype=np.float64)

    f_min = sysid_freqs[0]
    f_max = sysid_freqs[-1]

    # PCHIP in log domain (prevents undershoot/overshoot)
    pchip = PchipInterpolator(sysid_freqs, np.log(sysid_gain))

    # In-range: PCHIP
    in_range = (f >= f_min) & (f <= f_max)
    mag[in_range] = np.exp(pchip(f[in_range]))

    # Above range: 1-pole extrapolation from last measured point
    above = f > f_max
    if np.any(above):
        # H_1p(f) = 1/sqrt(1 + (f/fc)^2)
        # ratio = H_1p(f) / H_1p(f_max) to anchor at last measured value
        scale_at_max = np.sqrt(1 + (f_max / fc_1p)**2)
        mag[above] = sysid_gain[-1] * scale_at_max / np.sqrt(1 + (f[above] / fc_1p)**2)

    # DC
    mag[0] = 1.0

    # Safety: no zeros
    mag = np.maximum(mag, 1e-6)

    return mag


def _cepstral_min_phase(mag_half, N):
    """Compute minimum-phase from one-sided magnitude spectrum.

    Args:
        mag_half: |H(f)| for f = 0, df, 2*df, ..., fs/2. Shape (N//2+1,).
                  Corresponds to rfft output bins.
        N:        full signal length (even). Used to construct Hermitian spectrum.

    Returns:
        phi: minimum-phase angle (radians), same shape as mag_half.

    Method:
        1. Build full Hermitian-symmetric log-magnitude spectrum (length N)
        2. Take real cepstrum (IFFT of log-magnitude)
        3. Apply causal window (keep n>=0, double n>0, zero n<0)
        4. FFT back -> complex spectrum whose angle is the minimum phase

    This is mathematically identical to phi = -imag(hilbert(ln|H|)) but
    implemented via the cepstrum for numerical stability.
    """
    n_pos = len(mag_half)       # N//2 + 1

    log_mag_half = np.log(mag_half)

    # Full Hermitian-symmetric log-magnitude: [DC, f1..fN/2, fN/2-1..f1]
    log_mag_full = np.concatenate([log_mag_half, log_mag_half[-2:0:-1]])

    # Real cepstrum
    cepstrum = np.real(np.fft.ifft(log_mag_full))

    # Causal window: n=0 -> x1, n=1..N/2-1 -> x2, n=N/2 -> x1, rest -> x0
    win = np.zeros(N)
    win[0] = 1.0
    win[1:N//2] = 2.0
    win[N//2] = 1.0

    # Reconstruct minimum-phase complex spectrum
    min_phase_spec = np.exp(np.fft.fft(cepstrum * win))

    # Extract phase for positive frequencies only
    phi = np.angle(min_phase_spec[:n_pos])

    return phi


def apply_compensation(signal, sysid_freqs, sysid_gain, fc_1p, fs,
                       eps_floor, eps_wall, f_edge, df_trans):
    """Apply Method B Wiener compensation via single rfft/irfft.

    This function:
      1. Takes rfft of the entire signal -> N//2+1 frequency bins
      2. Builds the AFE model H_AFE(f) on that exact grid (no interpolation of H)
      3. Computes the Wiener inverse G(f)
      4. Multiplies X(f) * G(f)
      5. Takes irfft to get the compensated time-domain signal

    rfft returns only positive frequencies (bins 0 to N//2).
    irfft reconstructs the full signal using Hermitian symmetry:
      X[N-k] = conj(X[k])
    This is automatically enforced because:
      - mag(f) is real and symmetric (same value at +f and -f)
      - phi(f) from cepstral method obeys minimum-phase symmetry
      - eps(f) is real and symmetric
    So G(f) has the correct conjugate-symmetric structure, and
    X(f)*G(f) preserves Hermitian symmetry -> irfft gives a real output.

    Args:
        signal:       time-domain signal, 1D array, length N
        sysid_freqs:  sysid frequency points (Hz)
        sysid_gain:   sysid gain ratios at those points
        fc_1p:        1-pole fc (Hz) for extrapolation above 120 kHz
        fs:           sample rate (Hz)
        eps_floor:    regularization floor
        eps_wall:     regularization wall strength
        f_edge:       rolloff center frequency (Hz)
        df_trans:     rolloff transition half-width (Hz)

    Returns:
        compensated signal, same length as input
    """
    N = len(signal)

    # -- Step 1: Forward FFT (positive frequencies only) --
    X = np.fft.rfft(signal)                  # shape: (N//2 + 1,)
    f = np.fft.rfftfreq(N, 1.0 / fs)        # shape: (N//2 + 1,)

    # -- Step 2: Build |H_AFE(f)| on this grid --
    mag = _build_magnitude_on_grid(f, sysid_freqs, sysid_gain, fc_1p)

    # -- Step 3: Compute minimum phase --
    phi = _cepstral_min_phase(mag, N)

    # -- Step 4: Form complex AFE model --
    H_afe = mag * np.exp(1j * phi)

    # -- Step 5: Frequency-dependent regularization --
    sigmoid = 0.5 * (1.0 + np.tanh((f - f_edge) / df_trans))
    eps_f = eps_floor + eps_wall * sigmoid

    # -- Step 6: Wiener inverse --
    G = np.conj(H_afe) / (np.abs(H_afe)**2 + eps_f)

    # -- Step 7: Apply and inverse FFT --
    X_comp = X * G
    return np.fft.irfft(X_comp, n=N)


# ============================================================
#  HELPERS — CAPTURE
# ============================================================

def ssh_connect():
    ssh = paramiko.SSHClient()
    # Trusted point-to-point link to a dedicated board at a fixed private
    # IP on an isolated segment, so auto-accepting its host key is fine
    # here. Use load_host_keys()/RejectPolicy on a shared network.
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(ZED_IP, username=ZED_USER, password=ZED_PASS, timeout=5)
    return ssh


def next_filename(save_dir):
    i = 1
    while os.path.exists(os.path.join(save_dir, f"capture{i}.mat")):
        i += 1
    return os.path.join(save_dir, f"capture{i}.mat")


def render_progress(message, elapsed, duration):
    bar_len = 30
    frac = min(elapsed / duration, 1.0)
    filled = int(bar_len * frac)
    bar = "█" * filled + "░" * (bar_len - filled)
    sys.stdout.write(f"\r  {message} [{bar}] {elapsed:.1f}/{duration:.0f}s ")
    sys.stdout.flush()


# ============================================================
#  HELPERS — SIGNAL PROCESSING
# ============================================================

def compute_fft(data, fs, window='hann'):
    N = len(data)
    win = sig.get_window(window, N)
    win_sum = np.sum(win)
    fft_vals = np.fft.rfft(data * win)
    freqs = np.fft.rfftfreq(N, 1/fs)
    magnitude = 2.0 * np.abs(fft_vals) / win_sum
    magnitude[0] /= 2.0
    return freqs, magnitude


def find_peaks_in_fft(freqs, magnitude, n_peaks=5, min_freq=500):
    mask = freqs >= min_freq
    f_search = freqs[mask]
    m_search = magnitude[mask]
    peak_indices, _ = sig.find_peaks(m_search, distance=5)
    if len(peak_indices) == 0:
        return []
    sorted_idx = np.argsort(m_search[peak_indices])[::-1]
    top_idx = peak_indices[sorted_idx[:n_peaks]]
    return [(f_search[i], m_search[i]) for i in top_idx]


# ============================================================
#  VISUALIZATION
# ============================================================



def _maximize_window():
    """Maximize current figure window across matplotlib backends. Silent no-op
    if none of the known calls work (Agg / headless)."""
    try:
        mgr = plt.get_current_fig_manager()
    except Exception:
        return
    attempts = (
        lambda: mgr.window.showMaximized(),          # Qt5/6
        lambda: mgr.window.state('zoomed'),          # TkAgg on Windows
        lambda: mgr.window.wm_state('zoomed'),       # TkAgg alt
        lambda: mgr.frame.Maximize(True),            # wxAgg
        lambda: mgr.resize(*mgr.window.maxsize()),   # TkAgg generic fallback
        lambda: mgr.full_screen_toggle(),            # last resort (toggles fullscreen)
    )
    for fn in attempts:
        try:
            fn()
            return
        except Exception:
            continue


def _annotate_peak(ax, pk_f, pk_a, rank, flip_left, log_x=True):
    """Pinned MATLAB-style datatip: marker at data point + callout box in a
    fixed axes-fraction slot near the top of the panel, so labels never
    collide vertically regardless of where the peaks land in amplitude."""
    y_db  = 20.0 * np.log10(max(pk_a, 1e-12))
    x_khz = pk_f / 1e3

    # Marker at the actual peak in data coords.
    ax.plot(x_khz, y_db,
            marker='v', color='black',
            markersize=8, markerfacecolor='yellow',
            markeredgewidth=0.9, zorder=5)

    # Label position in axes fraction. X tracks the marker (log-mapped);
    # Y is a fixed slot per rank → guaranteed vertical separation.
    xlim = ax.get_xlim()
    if log_x:
        x_frac = ((np.log10(max(x_khz, xlim[0])) - np.log10(xlim[0]))
                  / (np.log10(xlim[1]) - np.log10(xlim[0])))
    else:
        x_frac = (x_khz - xlim[0]) / (xlim[1] - xlim[0])

    nudge = 0.012
    if flip_left:
        x_lbl = max(0.02, x_frac - nudge);  ha = 'right'
    else:
        x_lbl = min(0.98, x_frac + nudge);  ha = 'left'

    # Three stacked slots in the upper portion of the panel.
    y_lbl = 0.93 - rank * 0.135

    ax.annotate(
        f'{pk_f:,.1f} Hz\n{y_db:+.2f} dBV',
        xy=(x_khz, y_db), xycoords='data',
        xytext=(x_lbl, y_lbl), textcoords='axes fraction',
        fontsize=10, fontfamily='monospace',
        ha=ha, va='center',
        bbox=dict(boxstyle='round,pad=0.35',
                  facecolor='lightyellow', edgecolor='black',
                  linewidth=0.8, alpha=0.95),
        arrowprops=dict(arrowstyle='-', color='black',
                        linewidth=0.8, shrinkA=0, shrinkB=5),
        zorder=10)


def plot_dual_capture(ch0_V, ch0_comp, ch1_V, ch1_comp, fs, base_name):
    """4×1 fullscreen quick-look for field sensor captures.

      Row 1: Ch0 compensated time-domain
      Row 2: Ch1 compensated time-domain   (shares x-axis with Row 1)
      Row 3: Ch0 Welch PSD (compensated)
      Row 4: Ch1 Welch PSD (compensated)   (shares x-axis with Row 3)

    Spectrum: Welch periodogram, Hann window, 50 % overlap, 'spectrum' scaling
    (V² per bin → dBV²; calibration-traceable across NFFT). Adaptive NFFT
    targeting WELCH_TARGET_AVG averages, snapped to nearest power of 2,
    clamped to [2^12, 2^17] AND ≤ 2^floor(log2(N)).

    Time panels share the same y-limits. PSD panels share the same dB y-limits.
    All time samples plotted (rasterized) — min/max decimation aliases periodic
    content above ~1 cycle/bin.
    """

    N = len(ch0_comp)
    t_ms = np.arange(N) * (1e3 / fs)

    # DC offsets reported, then subtracted (drift visible in waveform plots).
    dc0 = float(np.mean(ch0_comp))
    dc1 = float(np.mean(ch1_comp))
    comp0_ac = ch0_comp - dc0
    comp1_ac = ch1_comp - dc1

    # -- Adaptive NFFT (matches MATLAB rule in daq_analysis_dual_v3.m) --
    target_avg = WELCH_TARGET_AVG
    nfft_raw   = 2 * N / target_avg
    nfft       = int(2 ** round(np.log2(max(nfft_raw, 4096.0))))
    nfft       = max(2**12, min(2**17, nfft))
    nfft       = min(nfft, 2 ** int(np.floor(np.log2(N))))
    n_overlap  = nfft // 2
    n_avg      = max(1, (N - n_overlap) // (nfft - n_overlap))
    df_bin_Hz  = fs / nfft

    # -- Welch PSD: 'spectrum' scaling = V² per bin (= MATLAB pwelch 'power') --
    f_Hz, pxx0 = sig.welch(comp0_ac, fs=fs, window='hann', nperseg=nfft,
                            noverlap=n_overlap, nfft=nfft, scaling='spectrum',
                            detrend=False, return_onesided=True)
    _,    pxx1 = sig.welch(comp1_ac, fs=fs, window='hann', nperseg=nfft,
                            noverlap=n_overlap, nfft=nfft, scaling='spectrum',
                            detrend=False, return_onesided=True)
    db0_full = 10.0 * np.log10(pxx0 + 1e-20)
    db1_full = 10.0 * np.log10(pxx1 + 1e-20)

    # Top-3 peaks per channel (skip sidelobes via min-distance constraint).
    peaks_ch0 = _find_psd_peaks(f_Hz, db0_full, n_peaks=3,
                                min_freq=500.0, min_sep_Hz=200.0)
    peaks_ch1 = _find_psd_peaks(f_Hz, db1_full, n_peaks=3,
                                min_freq=500.0, min_sep_Hz=200.0)

    # -- Shared limits --
    y_abs_max = max(float(np.max(np.abs(comp0_ac))),
                    float(np.max(np.abs(comp1_ac))),
                    1e-6)
    y_lim_t = (-1.05 * y_abs_max, 1.05 * y_abs_max)

    fmask = f_Hz >= 500.0
    db_top = max(float(np.max(db0_full[fmask])), float(np.max(db1_full[fmask])))
    db_bot = min(float(np.min(db0_full[fmask])), float(np.min(db1_full[fmask])))
    y_lim_f = (db_bot - 3.0, db_top + 10.0)   # headroom for pinned labels

    # -- Figure size (hardcoded per display) ------------------------------
    # tight_layout reserves decoration padding in proportion to figsize.
    # Too-small figsize → padding dominates → axes look cramped even after
    # maximize. Pick a figsize close to the actual display area.
    #
    #   Swap based on host:
    #     HP Spectre (laptop, field):       (14, 8)     ← active
    #     Prior PC (desktop / ext monitor): (20, 11)
    # --------------------------------------------------------------------
    FIG_SIZE_IN = (14, 8)          # HP Spectre
    # FIG_SIZE_IN = (20, 11)       # Prior PC

    fig, axes = plt.subplots(4, 1, figsize=FIG_SIZE_IN)
    ax_t0, ax_t1, ax_f0, ax_f1 = axes
    ax_t0.sharex(ax_t1)
    ax_f0.sharex(ax_f1)

    fig.suptitle(
        f'{os.path.basename(base_name)}   |   Fs={fs/1e3:.1f} kSPS   |   '
        f'{N:,} samples ({N/fs:.2f} s)   |   '
        f'Welch [nfft={nfft}, {n_avg} avg, df={df_bin_Hz:.1f} Hz]   |   '
        f'Method B Wiener — compensated',
        fontsize=11, fontweight='bold')

    # Row 1 — Ch0 time
    ax_t0.plot(t_ms, comp0_ac, color='#c72020', linewidth=0.6, rasterized=True)
    ax_t0.set_ylabel('Ch0  (V)', fontsize=11)
    ax_t0.set_title(f'Ch0 — Compensated Waveform   (DC offset removed: {dc0:+.4f} V)',
                    fontsize=11, fontweight='bold', loc='left')
    ax_t0.set_ylim(y_lim_t); ax_t0.grid(True, alpha=0.3)
    ax_t0.tick_params(labelbottom=False)
    ax_t0.axhline(0, color='k', linewidth=0.4, alpha=0.5)

    # Row 2 — Ch1 time
    ax_t1.plot(t_ms, comp1_ac, color='#c72020', linewidth=0.6, rasterized=True)
    ax_t1.set_xlabel('Time  (ms)', fontsize=11)
    ax_t1.set_ylabel('Ch1  (V)', fontsize=11)
    ax_t1.set_title(f'Ch1 — Compensated Waveform   (DC offset removed: {dc1:+.4f} V)',
                    fontsize=11, fontweight='bold', loc='left')
    ax_t1.set_ylim(y_lim_t); ax_t1.grid(True, alpha=0.3)
    ax_t1.axhline(0, color='k', linewidth=0.4, alpha=0.5)

    # Row 3 — Ch0 Welch PSD
    ax_f0.semilogx(f_Hz[fmask]/1e3, db0_full[fmask],
                   color='#c72020', linewidth=0.7, rasterized=True)
    ax_f0.set_ylabel('Ch0  (dBV²)', fontsize=11)
    ax_f0.set_title('Ch0 — Welch PSD (compensated)', fontsize=11, fontweight='bold', loc='left')
    ax_f0.set_xlim([0.5, fs/2e3])
    ax_f0.set_ylim(y_lim_f)
    ax_f0.grid(True, alpha=0.3, which='both')
    ax_f0.tick_params(labelbottom=False)
    for rank, (pk_f, pk_db) in enumerate(peaks_ch0):
        _annotate_peak_db(ax_f0, pk_f, pk_db, rank, flip_left=(pk_f > 70000))

    # Row 4 — Ch1 Welch PSD
    ax_f1.semilogx(f_Hz[fmask]/1e3, db1_full[fmask],
                   color='#c72020', linewidth=0.7, rasterized=True)
    ax_f1.set_xlabel('Frequency  (kHz)', fontsize=11)
    ax_f1.set_ylabel('Ch1  (dBV²)', fontsize=11)
    ax_f1.set_title('Ch1 — Welch PSD (compensated)', fontsize=11, fontweight='bold', loc='left')
    ax_f1.set_xlim([0.5, fs/2e3])
    ax_f1.set_ylim(y_lim_f)
    ax_f1.grid(True, alpha=0.3, which='both')
    for rank, (pk_f, pk_db) in enumerate(peaks_ch1):
        _annotate_peak_db(ax_f1, pk_f, pk_db, rank, flip_left=(pk_f > 70000))

    plt.tight_layout(rect=[0, 0, 1, 0.96])

    # PNG save intentionally disabled (live quick-look only).
    # png_path = base_name.replace('.mat', '_analysis.png')
    # plt.savefig(png_path, dpi=120, bbox_inches='tight')

    _maximize_window()
    plt.show()

    # -- Console summary --
    print()
    print(f"  DC offsets — Ch0: {dc0:+.4f} V    Ch1: {dc1:+.4f} V")
    print(f"  Welch     — nfft={nfft}, {n_avg} averages, df={df_bin_Hz:.2f} Hz, hann, 50% overlap")
    print()
    print("  TOP 3 PEAKS — Welch PSD")
    hdr = (f"  {'rank':>4s}   {'Ch0 freq (Hz)':>14s}  {'Ch0 (dBV²)':>11s}   "
           f"{'Ch1 freq (Hz)':>14s}  {'Ch1 (dBV²)':>11s}")
    print(hdr)
    print('  ' + '-' * (len(hdr) - 2))
    for i in range(3):
        if i < len(peaks_ch0):
            s0f = f"{peaks_ch0[i][0]:>14,.2f}"
            s0a = f"{peaks_ch0[i][1]:>+11.2f}"
        else:
            s0f, s0a = '—'.rjust(14), '—'.rjust(11)
        if i < len(peaks_ch1):
            s1f = f"{peaks_ch1[i][0]:>14,.2f}"
            s1a = f"{peaks_ch1[i][1]:>+11.2f}"
        else:
            s1f, s1a = '—'.rjust(14), '—'.rjust(11)
        print(f"  {i+1:>4d}   {s0f}  {s0a}   {s1f}  {s1a}")


def _find_psd_peaks(f_Hz, db, n_peaks=3, min_freq=500.0, min_sep_Hz=200.0):
    """Top-N peaks in a dB PSD, skipping sidelobes via min-distance.
    Returns list of (frequency_Hz, dB_value) sorted by descending dB."""
    df = float(f_Hz[1] - f_Hz[0])
    distance = max(1, int(round(min_sep_Hz / df)))
    mask = f_Hz >= min_freq
    f_search  = f_Hz[mask]
    db_search = db[mask]
    pk_idx, _ = sig.find_peaks(db_search, distance=distance)
    if len(pk_idx) == 0:
        return []
    order = np.argsort(db_search[pk_idx])[::-1]
    top = pk_idx[order[:n_peaks]]
    return [(float(f_search[i]), float(db_search[i])) for i in top]


def _annotate_peak_db(ax, pk_f, pk_db, rank, flip_left, log_x=True):
    """Pinned MATLAB-style datatip in fixed axes-fraction slots — guarantees
    no vertical overlap regardless of where peaks land in amplitude."""
    x_khz = pk_f / 1e3

    ax.plot(x_khz, pk_db,
            marker='v', color='black',
            markersize=8, markerfacecolor='yellow',
            markeredgewidth=0.9, zorder=5)

    xlim = ax.get_xlim()
    if log_x:
        x_frac = ((np.log10(max(x_khz, xlim[0])) - np.log10(xlim[0]))
                  / (np.log10(xlim[1]) - np.log10(xlim[0])))
    else:
        x_frac = (x_khz - xlim[0]) / (xlim[1] - xlim[0])

    nudge = 0.012
    if flip_left:
        x_lbl = max(0.02, x_frac - nudge);  ha = 'right'
    else:
        x_lbl = min(0.98, x_frac + nudge);  ha = 'left'

    y_lbl = 0.93 - rank * 0.135

    ax.annotate(
        f'{pk_f:,.2f} Hz\n{pk_db:+.2f} dBV²',
        xy=(x_khz, pk_db), xycoords='data',
        xytext=(x_lbl, y_lbl), textcoords='axes fraction',
        fontsize=10, fontfamily='monospace',
        ha=ha, va='center',
        bbox=dict(boxstyle='round,pad=0.35',
                  facecolor='lightyellow', edgecolor='black',
                  linewidth=0.8, alpha=0.95),
        arrowprops=dict(arrowstyle='-', color='black',
                        linewidth=0.8, shrinkA=0, shrinkB=5),
        zorder=10)


# ============================================================
#  MAIN
# ============================================================

if __name__ == '__main__':

    ssh = None
    local_bin = None

    try:
        ensure_output_directory(SAVE_DIR)
        filename = next_filename(SAVE_DIR)
        temp_fd, local_bin = tempfile.mkstemp(
            prefix=".capture-", suffix=".bin", dir=SAVE_DIR
        )
        os.close(temp_fd)
        os.remove(local_bin)

        # -- Connect --
        ssh = ssh_connect()

        # -- Ready prompt --
        print()
        print("=" * 60)
        print(f"  DUAL-CHANNEL CAPTURE — Method B Wiener Compensation")
        print(f"  File:     {filename}")
        rate_str = f"{FS/1e6:.1f} MSPS" if FS >= 1000000 else f"{FS/1000:.0f} kSPS"
        print(f"  Rate:     {rate_str}  |  Duration: {CAPTURE_SECONDS}s")
        print(f"  Samples:  {TOTAL_SAMPLES:,} per channel")
        print(f"  Comp:     Method B Wiener (24-pt sysid, cepstral phase)")
        print(f"            Single-FFT: compensator built on signal's native grid")
        print(f"  Rolloff:  {F_EDGE/1e3:.0f} kHz edge, {DF_TRANS/1e3:.0f} kHz transition")
        print("=" * 60)
        input(">>> Press ENTER to start capture... ")
        print()
        print("  RECORDING — perform hammer strikes now!")
        print()

        # -- Capture --
        t_start = time.time()
        run_remote_capture(
            ssh,
            TOTAL_SAMPLES,
            IIO_BUFFER_SIZE,
            FS,
            REMOTE_BIN,
            CAPTURE_SECONDS + CAPTURE_TIMEOUT_MARGIN_S,
            progress_callback=lambda elapsed: render_progress(
                "Capturing", elapsed, CAPTURE_SECONDS
            ),
        )
        t_capture = time.time() - t_start
        render_progress("Capturing", CAPTURE_SECONDS, CAPTURE_SECONDS)
        print()

        # -- Transfer --
        print()
        sys.stdout.write("  Transferring data... ")
        sys.stdout.flush()
        t_xfer = time.time()
        pull_capture(ssh, REMOTE_BIN, local_bin, TOTAL_SAMPLES)
        t_xfer = time.time() - t_xfer
        print(f"done ({t_xfer:.1f}s)")

        # -- Parse both channels --
        sys.stdout.write("  Parsing... ")
        sys.stdout.flush()
        ch0_raw, ch1_raw = parse_binary_dual(
            local_bin, expected_samples=TOTAL_SAMPLES
        )
        print("done")
    except (AcquisitionError, OSError) as exc:
        print()
        print(f"ERROR: Capture aborted: {exc}")
        sys.exit(1)
    except Exception as exc:
        print()
        print(f"ERROR: Cannot complete acquisition ({exc})")
        sys.exit(1)
    finally:
        for warning in cleanup_capture_resources(
            ssh, REMOTE_BIN, local_bin
        ):
            print(f"  Cleanup warning: {warning}")

    # -- Calibrate both channels --
    ch0_V = ch0_raw.astype(np.float64) * GAIN_CH0 + OFFSET_CH0
    ch1_V = ch1_raw.astype(np.float64) * GAIN_CH1 + OFFSET_CH1

    # -- Apply compensation (single FFT per channel) --
    print()
    sys.stdout.write("  Compensating Ch0 (single-FFT)... ")
    sys.stdout.flush()
    t_comp = time.time()
    ch0_ac = ch0_V - np.mean(ch0_V)
    ch0_comp_ac = apply_compensation(
        ch0_ac, SYSID_FREQS, SYSID_GAIN_CH0, FC_CH0, FS,
        EPS_FLOOR, EPS_WALL, F_EDGE, DF_TRANS)
    ch0_comp = ch0_comp_ac + np.mean(ch0_V)
    t0 = time.time() - t_comp
    print(f"done ({t0:.1f}s)")

    sys.stdout.write("  Compensating Ch1 (single-FFT)... ")
    sys.stdout.flush()
    t_comp = time.time()
    ch1_ac = ch1_V - np.mean(ch1_V)
    ch1_comp_ac = apply_compensation(
        ch1_ac, SYSID_FREQS, SYSID_GAIN_CH1, FC_CH1, FS,
        EPS_FLOOR, EPS_WALL, F_EDGE, DF_TRANS)
    ch1_comp = ch1_comp_ac + np.mean(ch1_V)
    t1 = time.time() - t_comp
    print(f"done ({t1:.1f}s)")

    # -- Save --
    sys.stdout.write("  Saving... ")
    sys.stdout.flush()
    savemat(filename, {
        # -- Source-of-truth raw ADC counts (int32). All downstream signals
        #    (calibrated voltages, compensated voltages) are recomputable from
        #    these + metadata via the apply_method_b helper in the MATLAB script.
        #    To re-add a derived array, insert it here, e.g.:
        #        'ch0_compensated':  ch0_comp,
        #        'ch0_V':            ch0_V,
        'ch0_raw':          ch0_raw,
        'ch1_raw':          ch1_raw,

        # -- Acquisition metadata --
        'sample_rate':      FS,
        'duration_s':       CAPTURE_SECONDS,

        # -- Calibration (voltage = raw * gain + offset) --
        'gain_ch0':         GAIN_CH0,
        'offset_ch0':       OFFSET_CH0,
        'gain_ch1':         GAIN_CH1,
        'offset_ch1':       OFFSET_CH1,

        # -- Compensation metadata (Method B, frozen) --
        'compensation':     'method_b_wiener_cepstral_single_fft',
        'comp_eps_floor':   EPS_FLOOR,
        'comp_eps_wall':    EPS_WALL,
        'comp_f_edge':      F_EDGE,
        'comp_df_trans':    DF_TRANS,
        'sysid_freqs':      SYSID_FREQS,
        'sysid_gain_ch0':   SYSID_GAIN_CH0,
        'sysid_gain_ch1':   SYSID_GAIN_CH1,
        'fc_ch0':           FC_CH0,
        'fc_ch1':           FC_CH1,
    }, do_compression=True)
    print("done")

    # -- Summary --
    t_total = time.time() - t_start
    print()
    print(f"  Saved: {filename}")
    print(f"  Samples: {len(ch0_V):,}/ch  |  Fs: {rate_str}  |  Duration: {len(ch0_V)/FS:.1f}s")
    print(f"  Ch0 range: {np.min(ch0_V):.4f}V to {np.max(ch0_V):.4f}V")
    print(f"  Ch1 range: {np.min(ch1_V):.4f}V to {np.max(ch1_V):.4f}V")
    print(f"  I/O time:   capture {t_capture:.1f}s + transfer {t_xfer:.1f}s")
    print(f"  Comp time: Ch0 {t0:.1f}s + Ch1 {t1:.1f}s")
    print(f"  Total:     {t_total:.1f}s (capture + transfer + processing)")

    # -- Visualization --
    print()
    print("=" * 60)
    print("  DUAL-CHANNEL ANALYSIS")
    print("=" * 60)
    print()
    plot_dual_capture(ch0_V, ch0_comp, ch1_V, ch1_comp, FS, filename)
    print()
    print("  Done. Close the plot window to exit.")
