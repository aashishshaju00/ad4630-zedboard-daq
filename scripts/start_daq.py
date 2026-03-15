import numpy as np
import paramiko
import time
from scipy.io import savemat
from scipy import signal as sig
import os
import sys
import matplotlib.pyplot as plt

# ── Hardware / Network ──────────────────────────────────────
ZED_IP   = "192.168.1.100"
ZED_USER = "root"
ZED_PASS = "analog"

# ── Calibration ─────────────────────────────────────────────
GAIN   = 0.0000006476
OFFSET = 0.148989
FS     = 500000          # 500 kSPS (250 kHz Nyquist) — change to 1000000 for 1 MSPS

# ── Capture Settings ────────────────────────────────────────
CAPTURE_SECONDS = 10
TOTAL_SAMPLES   = CAPTURE_SECONDS * FS
IIO_BUFFER_SIZE = 200000    # chunk size for iio_readdev on ZedBoard
REMOTE_BIN      = "/tmp/capture.bin"

# ── Save Directory ──────────────────────────────────────────
SAVE_DIR = "E:\\DAQ Data\\"

# ── Eval Board AFE Model (from Rev E schematic + measured data) ──
#
# ROOT CAUSE: ADA4945-1 input network on eval board (Sheet 4).
#   Schematic: R_gain=1kΩ (R17/R23), C_input=2700pF (C18/C24)
#   Nominal fc = 1/(2π × (R_source + 10 + 1000) × 2700pF) ≈ 55.6 kHz
#
# MEASURED POLE (from 17-point frequency sweep system identification):
#   Best fit: single-pole, fc = 53.5 ± 2.2 kHz (free gain, RMSE = 0.064V)
#   Two-pole fit found NO second pole (fc2 diverged to ∞)
#   Implied effective capacitance: 2806 pF (2700 pF + ~100 pF parasitics)
#   Schematic prediction (55.6 kHz) within 4% of measured
#
# ╔══════════════════════════════════════════════════════════════╗
# ║  TUNE THIS VALUE to match YOUR board's measured rolloff.    ║
# ║  Method: run freq_sweep_sysid.py for rigorous calibration.  ║
# ║  Quick check: feed a known sine, read FFT peak, solve:     ║
# ║    fc = f_test / sqrt((V_in/V_out)^2 - 1)                  ║
# ╚══════════════════════════════════════════════════════════════╝
AFE_FC_MEASURED = 53500     # Hz — MEASURED dominant pole frequency
                            # Set to None to use component-value calculation instead

# Component values (used only if AFE_FC_MEASURED is None)
AFE_R_GAIN     = 1000       # Ω — FDA gain resistor (R17/R23)
AFE_C_INPUT    = 2700e-12   # F — FDA input cap (C18/C24) ← THE BOTTLENECK
AFE_R_SMA      = 10         # Ω — board input resistor (R7/R34)
AFE_R_SETTLE   = 33         # Ω — output settling resistor (R35/R36)
AFE_C_SETTLE   = 1000e-12   # F — output settling cap (C42/C43)

# ── Visualization Settings ──────────────────────────────────
ZOOM_MS        = 0.5        # zoomed view window (ms)
FFT_WINDOW     = 'hann'     # FFT window function
COMP_FC_LIMIT  = 120e3      # compensation boost limit frequency (Hz)
                            # Higher = more accurate correction, but amplifies
                            # more noise above the signal band.
                            # 500 kHz gives <1% error at 80 kHz.


# ════════════════════════════════════════════════════════════
#  HELPERS — CAPTURE
# ════════════════════════════════════════════════════════════

def ssh_connect():
    """Open SSH connection to ZedBoard."""
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(ZED_IP, username=ZED_USER, password=ZED_PASS, timeout=5)
    return ssh


def remote_capture(ssh, samples, buf_size, sample_rate):
    """Set ADC sample rate and run iio_readdev on ZedBoard. Blocks until capture completes."""
    cmd = (
        f"iio_attr -u local: -d ad4630-24 sampling_frequency {sample_rate} && "
        f"iio_readdev -u local: -b {buf_size} -s {samples} ad4630-24"
        f" > {REMOTE_BIN}"
    )
    stdin, stdout, stderr = ssh.exec_command(cmd)
    exit_code = stdout.channel.recv_exit_status()
    return exit_code


def scp_pull(ssh, remote_path, local_path):
    """Pull a file from ZedBoard via SFTP."""
    sftp = ssh.open_sftp()
    sftp.get(remote_path, local_path)
    sftp.close()


def parse_binary(filepath):
    """Parse iio_readdev binary into separate channels.

    Binary format: 8 bytes per sample (2 × little-endian int32)
      Word 0 (Ch0): bits 31:8 = signed 24-bit differential, bits 7:0 = signed 8-bit common-mode
      Word 1 (Ch1): bits 31:8 = signed 24-bit differential, bits 7:0 = signed 8-bit common-mode
    """
    raw = np.fromfile(filepath, dtype=np.int32).reshape(-1, 2)
    ch0_diff = raw[:, 0] >> 8
    ch0_cm   = (raw[:, 0] & 0xFF).astype(np.int8)
    return ch0_diff, ch0_cm


def next_filename(save_dir):
    """Auto-increment data filename."""
    i = 1
    while os.path.exists(os.path.join(save_dir, f"data{i}.mat")):
        i += 1
    return os.path.join(save_dir, f"data{i}.mat")


def progress_wait(message, duration):
    """Show a simple progress bar for a timed wait."""
    bar_len = 30
    t0 = time.time()
    while True:
        elapsed = time.time() - t0
        frac = min(elapsed / duration, 1.0)
        filled = int(bar_len * frac)
        bar = "█" * filled + "░" * (bar_len - filled)
        sys.stdout.write(f"\r  {message} [{bar}] {elapsed:.1f}/{duration:.0f}s ")
        sys.stdout.flush()
        if elapsed >= duration:
            break
        time.sleep(0.2)


def restart_iiod(ssh):
    """Restart iiod on ZedBoard (manual fallback)."""
    print("  Restarting iiod...")
    ssh.exec_command("systemctl restart iiod")
    time.sleep(10)
    print("  iiod restarted.")


# ════════════════════════════════════════════════════════════
#  HELPERS — SIGNAL PROCESSING
# ════════════════════════════════════════════════════════════

def build_afe_model(R_source=50):
    """Build analog transfer function of the eval board AFE.

    Uses AFE_FC_MEASURED if set (recommended — calibrated from real data).
    Falls back to component-value calculation if AFE_FC_MEASURED is None.

    Signal path from schematic (02_063069 Rev E, Sheets 1 & 4):
      SMA → R_SMA(10Ω) → [R_gain(1kΩ) + C_input(2700pF)] → ADA4945-1
            → R_settle(33Ω) + C_settle(1nF) → ADC

    Args:
        R_source: source impedance driving the SMA (Ω).
                  50 for Siglent direct, ~1 for buffered op-amp output.
    Returns:
        scipy TransferFunction (continuous-time), pole frequency (Hz)
    """
    # Dominant pole: use measured value or calculate from components
    if AFE_FC_MEASURED is not None:
        fc_dominant = AFE_FC_MEASURED
    else:
        R_total = R_source + AFE_R_SMA + AFE_R_GAIN
        fc_dominant = 1 / (2 * np.pi * R_total * AFE_C_INPUT)

    tau_dominant = 1 / (2 * np.pi * fc_dominant)

    # Stage 1: SMA input RC — R=10Ω, C=0.01µF → fc=1.59 MHz (not limiting)
    tau1 = AFE_R_SMA * 10e-9
    s1 = sig.TransferFunction([1], [tau1, 1])

    # Stage 2: FDA input network — dominant pole
    s2 = sig.TransferFunction([1], [tau_dominant, 1])

    # Stage 3: Output settling — R=33Ω, C=1nF → fc=4.82 MHz (not limiting)
    tau3 = AFE_R_SETTLE * AFE_C_SETTLE
    s3 = sig.TransferFunction([1], [tau3, 1])

    # Cascade all three stages
    num = np.convolve(np.convolve(s1.num, s2.num), s3.num)
    den = np.convolve(np.convolve(s1.den, s2.den), s3.den)
    chain = sig.TransferFunction(num, den)

    return chain, fc_dominant


def build_compensation_filter(fc_pole, fc_limit, fs):
    """Build a digital compensation filter that inverts the AFE pole.

    Creates a 1st-order high-shelf: boosts frequencies above fc_pole,
    flattening the response. Boost is capped at fc_limit to avoid
    amplifying noise above the useful bandwidth.

    Args:
        fc_pole:  AFE dominant pole frequency (Hz)
        fc_limit: frequency above which boost is capped (Hz)
        fs:       digital sample rate (Hz)
    Returns:
        (b, a) digital filter coefficients
    """
    wc = 2 * np.pi * fc_pole
    wl = 2 * np.pi * fc_limit

    # Analog prototype: H(s) = (1 + s/wc) / (1 + s/wl)
    # This boosts by +3 dB at fc_pole, levels off at 20*log10(wl/wc) dB
    comp_analog = sig.TransferFunction([1/wc, 1], [1/wl, 1])
    comp_digital = comp_analog.to_discrete(1/fs, method='bilinear')

    return comp_digital.num, comp_digital.den


def apply_compensation_freq_domain(ch0_V, fc_pole, fc_limit, fs):
    """Apply AFE compensation in the frequency domain (zero-phase, no transients).

    This is the preferred method for post-processing:
      1. FFT the entire signal
      2. Multiply each bin by the inverse AFE response (with HF limit)
      3. IFFT back to time domain

    Advantages over causal IIR filtering (lfilter):
      - Zero startup transients (no filter initial conditions)
      - Exactly zero phase distortion (inherently linear-phase)
      - Exact compensation at every frequency bin
      - Fs-independent: same analytical formula regardless of sample rate

    The compensation transfer function is:
      H_comp(f) = (1 + j·f/fc) / (1 + j·f/fl)
    which inverts the dominant pole at fc and caps the boost at fl.

    Args:
        ch0_V:    calibrated voltage signal (1D array)
        fc_pole:  AFE dominant pole frequency (Hz)
        fc_limit: frequency above which boost is capped (Hz)
        fs:       sample rate (Hz)
    Returns:
        compensated signal (same length as input)
    """
    N = len(ch0_V)
    freqs = np.fft.rfftfreq(N, 1.0 / fs)

    # Compensation: inverse of single-pole LP, with HF limit
    #   AFE: H_afe(f) = 1 / (1 + j·f/fc)         ← attenuates above fc
    #   Inverse: 1/H_afe = 1 + j·f/fc             ← boosts above fc (unbounded)
    #   With limit: H_comp = (1 + j·f/fc) / (1 + j·f/fl)  ← bounded shelf
    wc = 2 * np.pi * fc_pole
    wl = 2 * np.pi * fc_limit
    w  = 2 * np.pi * freqs

    H_comp = (1.0 + 1j * w / wc) / (1.0 + 1j * w / wl)

    # Apply in frequency domain
    X = np.fft.rfft(ch0_V)
    X_comp = X * H_comp
    ch0_comp = np.fft.irfft(X_comp, n=N)

    return ch0_comp


def compute_fft(data, fs, window='hann'):
    """Compute single-sided amplitude spectrum.

    Args:
        data:   time-domain signal (1D array)
        fs:     sample rate (Hz)
        window: window function name
    Returns:
        freqs:     frequency vector (Hz)
        magnitude: amplitude spectrum (V peak, window-corrected)
    """
    N = len(data)
    win = sig.get_window(window, N)
    win_sum = np.sum(win)

    fft_vals = np.fft.rfft(data * win)
    freqs = np.fft.rfftfreq(N, 1/fs)
    magnitude = 2.0 * np.abs(fft_vals) / win_sum   # corrected amplitude
    magnitude[0] /= 2.0                              # DC bin: no doubling

    return freqs, magnitude


def find_peaks_in_fft(freqs, magnitude, n_peaks=5, min_freq=500):
    """Find the top N peaks in the FFT above min_freq.

    Returns list of (freq_Hz, amplitude_V) tuples, sorted by amplitude descending.
    """
    # Only search above min_freq to skip DC/low-freq drift
    mask = freqs >= min_freq
    f_search = freqs[mask]
    m_search = magnitude[mask]

    # Find local maxima
    peak_indices, properties = sig.find_peaks(m_search, distance=5)
    if len(peak_indices) == 0:
        return []

    # Sort by amplitude, take top N
    sorted_idx = np.argsort(m_search[peak_indices])[::-1]
    top_idx = peak_indices[sorted_idx[:n_peaks]]

    peaks = [(f_search[i], m_search[i]) for i in top_idx]
    return peaks


# ════════════════════════════════════════════════════════════
#  HELPERS — VISUALIZATION
# ════════════════════════════════════════════════════════════

def plot_capture_analysis(ch0_V, fs, save_dir, base_name, R_source=50):
    """Generate a streamlined analysis figure.

    Layout:
      Top (wide):      Full compensated time-domain capture
      Bottom-left:     Raw vs Compensated overlay (comp = dashed red)
      Bottom-right:    FFT overlay: raw vs compensated (log x-axis)

    Uses matplotlib's built-in toolbar for zoom/pan (fast, no TextBox lag).
    Data is downsampled for plotting when >50k points to keep interaction snappy.
    """
    from matplotlib.gridspec import GridSpec

    N = len(ch0_V)
    t = np.arange(N) / fs   # time vector in seconds
    t_ms = t * 1e3

    # ── AFE model ──
    afe_chain, fc_pole = build_afe_model(R_source=R_source)

    # ── Compensation: frequency-domain (zero-phase, no transients) ──
    ch0_comp = apply_compensation_freq_domain(ch0_V, fc_pole, COMP_FC_LIMIT, fs)

    # ── FFT of raw signal ──
    fft_freqs, fft_mag = compute_fft(ch0_V, fs, FFT_WINDOW)
    peaks_raw = find_peaks_in_fft(fft_freqs, fft_mag, n_peaks=5)

    # ── FFT of compensated signal ──
    fft_freqs_c, fft_mag_c = compute_fft(ch0_comp, fs, FFT_WINDOW)
    peaks_comp = find_peaks_in_fft(fft_freqs_c, fft_mag_c, n_peaks=5)

    # ── Downsample for plotting (keeps interaction snappy) ──
    MAX_PLOT_PTS = 50000
    if N > MAX_PLOT_PTS:
        ds = N // MAX_PLOT_PTS
        t_ds      = t_ms[::ds]
        raw_ds    = ch0_V[::ds]
        comp_ds   = ch0_comp[::ds]
    else:
        ds = 1
        t_ds      = t_ms
        raw_ds    = ch0_V
        comp_ds   = ch0_comp

    # ════════════════════════════════════════════════════════
    #  CREATE FIGURE
    # ════════════════════════════════════════════════════════
    fig = plt.figure(figsize=(18, 12))
    gs = GridSpec(2, 2, figure=fig, height_ratios=[1, 1.2],
                  hspace=0.35, wspace=0.3, top=0.89, bottom=0.07)

    fig.suptitle(f'Capture Analysis — {os.path.basename(base_name)}\n'
                 f'Fs = {fs/1e3:.0f} kSPS  |  {N:,} samples  |  '
                 f'AFE pole = {fc_pole/1e3:.1f} kHz  |  '
                 f'Comp limit = {COMP_FC_LIMIT/1e3:.0f} kHz  |  '
                 f'Max boost = {COMP_FC_LIMIT/fc_pole:.2f}× '
                 f'({20*np.log10(COMP_FC_LIMIT/fc_pole):.1f} dB)\n'
                 f'Compensation: frequency-domain (zero-phase)',
                 fontsize=13, fontweight='bold')

    # ────────────────────────────────────────────────────────
    # [Top, full width] Full time-domain COMPENSATED capture
    # ────────────────────────────────────────────────────────
    ax_full = fig.add_subplot(gs[0, :])
    ax_full.plot(t_ds, comp_ds, 'r-', linewidth=0.3)
    ax_full.set_xlabel('Time (ms)')
    ax_full.set_ylabel('Voltage (V)')
    ax_full.set_title('Full Capture — Compensated Time Domain')
    ax_full.grid(True, alpha=0.3)
    vmax_c = max(abs(np.min(ch0_comp)), abs(np.max(ch0_comp))) * 1.1
    ax_full.set_ylim([-vmax_c, vmax_c])

    # ────────────────────────────────────────────────────────
    # [Bottom-left] Raw vs Compensated overlay
    #   Raw = solid blue, Compensated = dashed red
    #   Use toolbar zoom/pan to inspect — much faster than TextBox
    # ────────────────────────────────────────────────────────
    ax_comp = fig.add_subplot(gs[1, 0])
    ax_comp.plot(t_ds, raw_ds, 'b-', linewidth=0.8, alpha=0.6, label='Raw')
    ax_comp.plot(t_ds, comp_ds, 'r--', linewidth=1.0, label='Compensated')
    ax_comp.set_xlabel('Time (ms)')
    ax_comp.set_ylabel('Voltage (V)')
    ax_comp.set_title('Raw vs Compensated — Time Domain  (use toolbar to zoom)')
    ax_comp.legend(fontsize=9, loc='upper right')
    ax_comp.grid(True, alpha=0.3)

    # Default zoom: first 10 ms or 3 cycles of dominant, whichever is larger
    default_xmax = min(10.0, N / fs * 1e3)
    if peaks_raw:
        f_dom = peaks_raw[0][0]
        if f_dom > 0:
            default_xmax = max(3.0 / f_dom * 1e3, 2.0)
            default_xmax = min(default_xmax, N / fs * 1e3)
    ax_comp.set_xlim([0, default_xmax])
    vmax = max(abs(np.min(ch0_V)), abs(np.max(ch0_V)),
               abs(np.min(ch0_comp)), abs(np.max(ch0_comp))) * 1.1
    ax_comp.set_ylim([-vmax, vmax])

    # ────────────────────────────────────────────────────────
    # [Bottom-right] FFT overlay: raw vs compensated (LOG x-axis)
    # ────────────────────────────────────────────────────────
    ax_fft = fig.add_subplot(gs[1, 1])
    fft_mag_dB = 20 * np.log10(np.maximum(fft_mag, 1e-10))
    fft_mag_c_dB = 20 * np.log10(np.maximum(fft_mag_c, 1e-10))

    mask = fft_freqs >= 500
    mask_c = fft_freqs_c >= 500
    ax_fft.plot(fft_freqs[mask] / 1e3, fft_mag_dB[mask],
                'b-', linewidth=0.8, alpha=0.5, label='Raw')
    ax_fft.plot(fft_freqs_c[mask_c] / 1e3, fft_mag_c_dB[mask_c],
                'r-', linewidth=0.8, label='Compensated')
    ax_fft.set_xscale('log')
    ax_fft.set_xlabel('Frequency (kHz)')
    ax_fft.set_ylabel('Amplitude (dBV)')
    ax_fft.set_title('FFT — Raw vs Compensated (log scale)')
    ax_fft.set_xlim([0.5, fs / 2e3])
    ax_fft.legend(fontsize=9)
    ax_fft.grid(True, alpha=0.3, which='both')

    # Annotate compensated peaks
    for pk_f, pk_a in peaks_comp[:3]:
        ax_fft.plot(pk_f / 1e3, 20*np.log10(pk_a+1e-10), 'r^', markersize=8)
        ax_fft.annotate(f'{pk_f/1e3:.1f} kHz\n{pk_a:.4f} V',
                        xy=(pk_f / 1e3, 20*np.log10(pk_a+1e-10)),
                        xytext=(pk_f / 1e3 * 1.5, 20*np.log10(pk_a+1e-10) + 3),
                        fontsize=8, color='red',
                        arrowprops=dict(arrowstyle='->', color='red', lw=1))

    # ── Save and show ──
    png_path = base_name.replace('.mat', '_analysis.png')
    plt.savefig(png_path, dpi=150, bbox_inches='tight')
    print(f"  Analysis saved: {png_path}")
    if ds > 1:
        print(f"  NOTE: Plots downsampled {ds}× for speed ({N//ds:,} pts displayed).")
    print(f"  TIP: Use the matplotlib toolbar (zoom, pan) to inspect details.")
    plt.show()

    # ── Print peak summary to console ──
    print()
    print("  ┌─────────────────────────────────────────────────────┐")
    print("  │              FFT PEAK SUMMARY                       │")
    print("  ├─────────────────────────────────────────────────────┤")
    print(f"  │  AFE dominant pole: {fc_pole/1e3:.1f} kHz (from sys ID sweep)   │")
    print(f"  │  Comp limit: {COMP_FC_LIMIT/1e3:.0f} kHz  |  "
          f"Max boost: {COMP_FC_LIMIT/fc_pole:.2f}× ({20*np.log10(COMP_FC_LIMIT/fc_pole):.1f} dB)  │")
    print(f"  │  Compensation: freq-domain (zero-phase, no transient)│")
    print("  ├───────────┬──────────────┬──────────────────────────┤")
    print("  │ Frequency │  Raw (V pk)  │  Compensated (V pk)      │")
    print("  ├───────────┼──────────────┼──────────────────────────┤")
    for pk_r in peaks_raw[:5]:
        pk_c_match = None
        for pk_c in peaks_comp:
            if abs(pk_c[0] - pk_r[0]) < 500:
                pk_c_match = pk_c
                break
        comp_str = f"{pk_c_match[1]:.4f}" if pk_c_match else "  —"
        boost = ""
        if pk_c_match and pk_r[1] > 0:
            boost_dB = 20*np.log10(pk_c_match[1] / pk_r[1])
            boost = f"  ({boost_dB:+.1f} dB)"
        print(f"  │ {pk_r[0]/1e3:7.1f} kHz│   {pk_r[1]:.4f}     │   {comp_str}{boost}")
    print("  └───────────┴──────────────┴──────────────────────────┘")

    return ch0_comp


# ════════════════════════════════════════════════════════════
#  MAIN
# ════════════════════════════════════════════════════════════

filename = next_filename(SAVE_DIR)
local_bin = os.path.join(SAVE_DIR, "_capture_temp.bin")

# ── Phase 1: Connect ──
try:
    ssh = ssh_connect()
except Exception as e:
    print(f"ERROR: Cannot connect to ZedBoard ({e})")
    sys.exit(1)

# ── Phase 2: Ready prompt ──
print()
print("=" * 50)
print(f"  READY TO CAPTURE")
print(f"  File:     {filename}")
rate_str = f"{FS/1e6:.1f} MSPS" if FS >= 1000000 else f"{FS/1000:.0f} kSPS"
print(f"  Rate:     {rate_str}  |  Duration: {CAPTURE_SECONDS}s")
print(f"  Samples:  {TOTAL_SAMPLES:,}")
print("=" * 50)
input(">>> Press ENTER to start capture... ")
print()
print("  RECORDING — perform hammer strikes now!")
print()

# ── Phase 3: Capture on ZedBoard (local IIO) ──
import threading

capture_done = threading.Event()
capture_result = [None]

def _capture_thread():
    capture_result[0] = remote_capture(ssh, TOTAL_SAMPLES, IIO_BUFFER_SIZE, FS)
    capture_done.set()

t_start = time.time()
thread = threading.Thread(target=_capture_thread)
thread.start()
progress_wait("Capturing", CAPTURE_SECONDS)

# Wait for actual completion (may take slightly longer than CAPTURE_SECONDS)
capture_done.wait(timeout=CAPTURE_SECONDS + 5)
t_capture = time.time() - t_start
print()

if capture_result[0] != 0:
    print(f"  WARNING: iio_readdev exited with code {capture_result[0]}")

# ── Phase 4: Transfer binary to Windows ──
print()
sys.stdout.write("  Transferring data... ")
sys.stdout.flush()
t_xfer = time.time()
scp_pull(ssh, REMOTE_BIN, local_bin)
t_xfer = time.time() - t_xfer
print(f"done ({t_xfer:.1f}s)")

# ── Phase 5: Parse, calibrate, save ──
sys.stdout.write("  Processing... ")
sys.stdout.flush()
ch0_raw, ch0_cm = parse_binary(local_bin)
ch0_V = ch0_raw.astype(np.float64) * GAIN + OFFSET

savemat(filename, {
    'ch0_V':        ch0_V,
    'ch0_raw':      ch0_raw,
    'ch0_cm':       ch0_cm,
    'sample_rate':  FS,
    'gain':         GAIN,
    'offset':       OFFSET,
    'duration_s':   CAPTURE_SECONDS,
})

# Clean up temp file
try:
    os.remove(local_bin)
except Exception:
    pass

print("done")

# ── Phase 6: Summary ──
t_total = time.time() - t_start
print()
print(f"  Saved: {filename}")
print(f"  Samples: {len(ch0_V):,}  |  Fs: {rate_str}  |  Duration: {len(ch0_V)/FS:.1f}s")
print(f"  Range: {np.min(ch0_V):.4f}V to {np.max(ch0_V):.4f}V")
print(f"  Timing: capture {t_capture:.1f}s + transfer {t_xfer:.1f}s = {t_total:.1f}s total")

ssh.close()

# ── Phase 7: Signal Processing & Visualization ──
print()
print("=" * 50)
print("  SIGNAL PROCESSING & ANALYSIS")
print("=" * 50)
print()

# Source impedance: 50 Ω for Siglent direct, ~1 Ω for buffered.
# Change this if you're driving through the AD847 buffer or the AA filter.
R_SOURCE = 50    # Ω — set to your source impedance

ch0_comp = plot_capture_analysis(ch0_V, FS, SAVE_DIR, filename, R_source=R_SOURCE)

# Save compensated data alongside original
comp_filename = filename.replace('.mat', '_compensated.mat')
savemat(comp_filename, {
    'ch0_V':           ch0_V,
    'ch0_compensated':  ch0_comp,
    'ch0_raw':          ch0_raw,
    'sample_rate':      FS,
    'gain':             GAIN,
    'offset':           OFFSET,
    'duration_s':       CAPTURE_SECONDS,
    'afe_fc_pole':      AFE_FC_MEASURED if AFE_FC_MEASURED else 1/(2*np.pi*(R_SOURCE + AFE_R_SMA + AFE_R_GAIN)*AFE_C_INPUT),
    'compensation':     'freq_domain_zero_phase',
})
print(f"  Compensated data saved: {comp_filename}")
print()
print("  Done. Close the plot window to exit.")