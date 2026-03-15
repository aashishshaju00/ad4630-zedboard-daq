import numpy as np
import paramiko
import time
from scipy.io import savemat, loadmat
from scipy import signal as sig
from scipy.optimize import curve_fit
import os
import sys
import matplotlib.pyplot as plt
import json

# ── Hardware / Network ──────────────────────────────────────
ZED_IP   = "192.168.1.100"
ZED_USER = "root"
ZED_PASS = "analog"

# ── Calibration ─────────────────────────────────────────────
GAIN   = 0.0000006476
OFFSET = 0.148989
FS     = 500000

# ── Capture Settings ────────────────────────────────────────
CAPTURE_SECONDS = 2        # 2 seconds per frequency (plenty for FFT)
TOTAL_SAMPLES   = CAPTURE_SECONDS * FS
IIO_BUFFER_SIZE = 200000
REMOTE_BIN      = "/tmp/capture.bin"

# ── Save Directory ──────────────────────────────────────────
SAVE_DIR = "E:\\DAQ Data\\"

# ── Frequency Sweep Configuration ───────────────────────────
# Input amplitude (peak voltage). Measure once at low freq to calibrate.
INPUT_VPP      = 4.0                 # Siglent setting (Vpp)
INPUT_VPEAK    = INPUT_VPP / 2.0     # Peak voltage

# Sweep frequencies (Hz) — logarithmically spaced for good Bode coverage
SWEEP_FREQS = [
    5000, 7500, 10000, 15000, 20000, 25000, 30000,
    40000, 50000, 60000, 70000, 75000, 80000,
    90000, 100000, 110000, 120000
]

# ── Schematic Model (for comparison) ────────────────────────
# From Rev E schematic Sheet 4: R_gain=1kΩ, C_input=2700pF
SCHEMATIC_R = 1060    # Ω (50Ω Siglent + 10Ω board + 1kΩ gain)
SCHEMATIC_C = 2700e-12  # F


# ════════════════════════════════════════════════════════════
#  HARDWARE HELPERS (same as rec_data.py)
# ════════════════════════════════════════════════════════════

def ssh_connect():
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(ZED_IP, username=ZED_USER, password=ZED_PASS, timeout=5)
    return ssh

def remote_capture(ssh, samples, buf_size, sample_rate):
    cmd = (
        f"iio_attr -u local: -d ad4630-24 sampling_frequency {sample_rate} && "
        f"iio_readdev -u local: -b {buf_size} -s {samples} ad4630-24"
        f" > {REMOTE_BIN}"
    )
    stdin, stdout, stderr = ssh.exec_command(cmd)
    exit_code = stdout.channel.recv_exit_status()
    return exit_code

def scp_pull(ssh, remote_path, local_path):
    sftp = ssh.open_sftp()
    sftp.get(remote_path, local_path)
    sftp.close()

def parse_binary(filepath):
    raw = np.fromfile(filepath, dtype=np.int32).reshape(-1, 2)
    ch0_diff = raw[:, 0] >> 8
    return ch0_diff


# ════════════════════════════════════════════════════════════
#  SIGNAL PROCESSING HELPERS
# ════════════════════════════════════════════════════════════

def extract_peak_amplitude(data, fs, target_freq, window='hann'):
    """Extract the amplitude at target_freq from FFT.

    Uses a narrow search window around the expected frequency
    to handle spectral leakage and slight frequency offsets.

    Returns: (peak_freq_Hz, peak_amplitude_Vpeak)
    """
    N = len(data)
    win = sig.get_window(window, N)
    win_sum = np.sum(win)

    fft_vals = np.fft.rfft(data * win)
    freqs = np.fft.rfftfreq(N, 1/fs)
    magnitude = 2.0 * np.abs(fft_vals) / win_sum

    # Search within ±2% of target frequency (or at least ±500 Hz)
    search_bw = max(target_freq * 0.02, 500)
    mask = (freqs >= target_freq - search_bw) & (freqs <= target_freq + search_bw)

    if not np.any(mask):
        return target_freq, 0.0

    idx_in_mask = np.argmax(magnitude[mask])
    peak_idx = np.where(mask)[0][idx_in_mask]

    return freqs[peak_idx], magnitude[peak_idx]


# ════════════════════════════════════════════════════════════
#  TRANSFER FUNCTION MODELS FOR CURVE FITTING
# ════════════════════════════════════════════════════════════

def model_1pole(f, fc, gain):
    """1st-order low-pass: H(f) = gain / sqrt(1 + (f/fc)^2)"""
    return gain / np.sqrt(1 + (f / fc)**2)

def model_2pole(f, fc1, fc2, gain):
    """2nd-order (two cascaded 1st-order poles):
    H(f) = gain / [sqrt(1 + (f/fc1)^2) * sqrt(1 + (f/fc2)^2)]
    """
    return gain / (np.sqrt(1 + (f/fc1)**2) * np.sqrt(1 + (f/fc2)**2))

def model_1pole_fixed_gain(f, fc):
    """1st-order low-pass with gain fixed at INPUT_VPEAK."""
    return INPUT_VPEAK / np.sqrt(1 + (f / fc)**2)


# ════════════════════════════════════════════════════════════
#  MAIN — DATA COLLECTION
# ════════════════════════════════════════════════════════════

def collect_sweep_data(sweep_freqs):
    """Interactive frequency sweep: prompts user to set each frequency,
    captures data, extracts peak amplitude.

    Returns: list of dicts with keys: freq_set, freq_measured, amplitude, raw_data
    """
    local_bin = os.path.join(SAVE_DIR, "_sweep_temp.bin")

    # Connect to ZedBoard
    try:
        ssh = ssh_connect()
    except Exception as e:
        print(f"ERROR: Cannot connect to ZedBoard ({e})")
        sys.exit(1)

    print()
    print("═" * 60)
    print("  FREQUENCY SWEEP — SYSTEM IDENTIFICATION")
    print("═" * 60)
    print(f"  Frequencies: {len(sweep_freqs)} points, {sweep_freqs[0]/1e3:.0f} kHz to {sweep_freqs[-1]/1e3:.0f} kHz")
    print(f"  Input:       {INPUT_VPP} Vpp ({INPUT_VPEAK} V peak)")
    print(f"  Capture:     {CAPTURE_SECONDS}s per frequency @ {FS/1e3:.0f} kSPS")
    print(f"  Total time:  ~{len(sweep_freqs) * (CAPTURE_SECONDS + 3):.0f}s")
    print("═" * 60)
    print()
    print("  Set Siglent to:")
    print(f"    Amplitude: {INPUT_VPP} Vpp (keep constant for ALL frequencies)")
    print(f"    Waveform:  Sine")
    print(f"    Output:    ON, Hi-Z mode")
    print()
    input(">>> Press ENTER when Siglent is configured... ")
    print()

    results = []

    for i, freq in enumerate(sweep_freqs):
        freq_khz = freq / 1e3
        print(f"  [{i+1}/{len(sweep_freqs)}] Set Siglent to {freq_khz:.1f} kHz")
        input(f"       >>> Press ENTER when frequency is set... ")

        # Capture
        sys.stdout.write(f"       Capturing {CAPTURE_SECONDS}s... ")
        sys.stdout.flush()
        t0 = time.time()
        exit_code = remote_capture(ssh, TOTAL_SAMPLES, IIO_BUFFER_SIZE, FS)
        if exit_code != 0:
            print(f"WARNING: iio_readdev exited with code {exit_code}")
        t_cap = time.time() - t0

        # Transfer
        sys.stdout.write("transferring... ")
        sys.stdout.flush()
        scp_pull(ssh, REMOTE_BIN, local_bin)

        # Parse and calibrate
        ch0_raw = parse_binary(local_bin)
        ch0_V = ch0_raw.astype(np.float64) * GAIN + OFFSET

        # Extract peak amplitude at the test frequency
        peak_freq, peak_amp = extract_peak_amplitude(ch0_V, FS, freq)

        gain_ratio = peak_amp / INPUT_VPEAK
        gain_dB = 20 * np.log10(gain_ratio) if gain_ratio > 0 else -999

        print(f"done ({t_cap:.1f}s)")
        print(f"       Peak: {peak_amp:.4f} V @ {peak_freq/1e3:.2f} kHz "
              f"(ratio: {gain_ratio:.4f}, {gain_dB:+.2f} dB)")
        print()

        results.append({
            'freq_set': freq,
            'freq_measured': peak_freq,
            'amplitude': peak_amp,
            'gain_ratio': gain_ratio,
            'gain_dB': gain_dB,
        })

    # Clean up
    ssh.close()
    try:
        os.remove(local_bin)
    except:
        pass

    return results


# ════════════════════════════════════════════════════════════
#  MAIN — ANALYSIS
# ════════════════════════════════════════════════════════════

def analyze_sweep(results):
    """Fit transfer function models to measured data and generate plots.

    Fits:
      1. Single-pole model (1 parameter: fc)
      2. Two-pole model (2 parameters: fc1, fc2)
      3. Single-pole free-gain model (2 parameters: fc, gain)

    Compares all fits against the schematic prediction.
    """
    freqs = np.array([r['freq_set'] for r in results])
    amps = np.array([r['amplitude'] for r in results])
    ratios = np.array([r['gain_ratio'] for r in results])
    gains_dB = np.array([r['gain_dB'] for r in results])

    # ── Schematic prediction ──
    fc_schematic = 1 / (2 * np.pi * SCHEMATIC_R * SCHEMATIC_C)
    f_model = np.logspace(np.log10(freqs[0]*0.5), np.log10(freqs[-1]*2), 500)
    H_schematic = INPUT_VPEAK / np.sqrt(1 + (f_model / fc_schematic)**2)

    # ── Fit 1: Single pole, gain fixed at INPUT_VPEAK ──
    try:
        popt1, pcov1 = curve_fit(model_1pole_fixed_gain, freqs, amps,
                                  p0=[50000], bounds=([1000], [500000]))
        fc1 = popt1[0]
        fc1_err = np.sqrt(pcov1[0, 0])
        H_fit1 = model_1pole_fixed_gain(f_model, *popt1)
        residuals1 = amps - model_1pole_fixed_gain(freqs, *popt1)
        rmse1 = np.sqrt(np.mean(residuals1**2))
    except Exception as e:
        fc1, fc1_err, rmse1 = 0, 0, 999
        H_fit1 = np.zeros_like(f_model)
        print(f"  WARNING: Single-pole fit failed: {e}")

    # ── Fit 2: Single pole with free gain ──
    try:
        popt2, pcov2 = curve_fit(model_1pole, freqs, amps,
                                  p0=[50000, INPUT_VPEAK],
                                  bounds=([1000, 0.1], [500000, 5.0]))
        fc2, gain2 = popt2
        fc2_err = np.sqrt(pcov2[0, 0])
        H_fit2 = model_1pole(f_model, *popt2)
        residuals2 = amps - model_1pole(freqs, *popt2)
        rmse2 = np.sqrt(np.mean(residuals2**2))
    except Exception as e:
        fc2, gain2, fc2_err, rmse2 = 0, 0, 0, 999
        H_fit2 = np.zeros_like(f_model)
        print(f"  WARNING: Free-gain pole fit failed: {e}")

    # ── Fit 3: Two cascaded poles with free gain ──
    try:
        popt3, pcov3 = curve_fit(model_2pole, freqs, amps,
                                  p0=[50000, 500000, INPUT_VPEAK],
                                  bounds=([1000, 10000, 0.1], [500000, 5000000, 5.0]))
        fc3a, fc3b, gain3 = popt3
        fc3a_err = np.sqrt(pcov3[0, 0])
        fc3b_err = np.sqrt(pcov3[1, 1])
        H_fit3 = model_2pole(f_model, *popt3)
        residuals3 = amps - model_2pole(freqs, *popt3)
        rmse3 = np.sqrt(np.mean(residuals3**2))
    except Exception as e:
        fc3a, fc3b, gain3, fc3a_err, fc3b_err, rmse3 = 0, 0, 0, 0, 0, 999
        H_fit3 = np.zeros_like(f_model)
        print(f"  WARNING: Two-pole fit failed: {e}")

    # ════════════════════════════════════════════════════════
    #  CONSOLE REPORT
    # ════════════════════════════════════════════════════════
    print()
    print("═" * 70)
    print("  SYSTEM IDENTIFICATION RESULTS")
    print("═" * 70)
    print()

    # Measured data table
    print("  ┌──────────┬────────────┬────────────┬────────────┐")
    print("  │ Freq(kHz)│ Ampl (V pk)│ Gain Ratio │  Gain (dB) │")
    print("  ├──────────┼────────────┼────────────┼────────────┤")
    for r in results:
        print(f"  │ {r['freq_set']/1e3:7.1f}  │   {r['amplitude']:.4f}   │   {r['gain_ratio']:.4f}   │  {r['gain_dB']:+6.2f}   │")
    print("  └──────────┴────────────┴────────────┴────────────┘")
    print()

    # Model comparison
    print("  ┌─────────────────────────────────────────────────────────────┐")
    print("  │                   MODEL FIT COMPARISON                     │")
    print("  ├─────────────────────────────────────────────────────────────┤")
    print(f"  │  Schematic prediction:    fc = {fc_schematic/1e3:.1f} kHz               │")
    print(f"  │    (R = {SCHEMATIC_R} Ω, C = {SCHEMATIC_C*1e12:.0f} pF)                         │")
    print("  ├─────────────────────────────────────────────────────────────┤")
    print(f"  │  Fit 1 (1 pole, fixed gain):                              │")
    print(f"  │    fc = {fc1/1e3:.2f} ± {fc1_err/1e3:.2f} kHz     RMSE = {rmse1:.4f} V      │")
    print("  ├─────────────────────────────────────────────────────────────┤")
    print(f"  │  Fit 2 (1 pole, free gain):                               │")
    print(f"  │    fc = {fc2/1e3:.2f} ± {fc2_err/1e3:.2f} kHz     gain = {gain2:.4f} V       │")
    print(f"  │    RMSE = {rmse2:.4f} V                                      │")
    print("  ├─────────────────────────────────────────────────────────────┤")
    print(f"  │  Fit 3 (2 poles, free gain):                              │")
    print(f"  │    fc1 = {fc3a/1e3:.2f} ± {fc3a_err/1e3:.2f} kHz                          │")
    print(f"  │    fc2 = {fc3b/1e3:.1f} ± {fc3b_err/1e3:.1f} kHz                          │")
    print(f"  │    gain = {gain3:.4f} V      RMSE = {rmse3:.4f} V              │")
    print("  └─────────────────────────────────────────────────────────────┘")
    print()

    # Best fit recommendation
    rmses = {'1-pole fixed': rmse1, '1-pole free': rmse2, '2-pole': rmse3}
    best = min(rmses, key=rmses.get)
    print(f"  Best fit: {best} (lowest RMSE = {rmses[best]:.4f} V)")
    print()

    # Effective capacitance back-calculation (for 1-pole free-gain fit)
    if fc2 > 0:
        C_effective = 1 / (2 * np.pi * SCHEMATIC_R * fc2)
        print(f"  Implied effective capacitance: {C_effective*1e12:.0f} pF")
        print(f"    (Schematic: {SCHEMATIC_C*1e12:.0f} pF → extra {(C_effective - SCHEMATIC_C)*1e12:.0f} pF from parasitics)")
    print()

    # ════════════════════════════════════════════════════════
    #  FIGURE 1: Empirical Bode Plot + Model Fits
    # ════════════════════════════════════════════════════════
    fig, axes = plt.subplots(2, 2, figsize=(16, 12))
    fig.suptitle('System Identification: Eval Board AFE Transfer Function\n'
                 f'Input: {INPUT_VPP} Vpp sine  |  Fs = {FS/1e3:.0f} kSPS  |  '
                 f'Siglent 50Ω → eval board SMA',
                 fontsize=14, fontweight='bold')

    # [0,0] Bode Magnitude — Linear (Amplitude in V)
    ax = axes[0, 0]
    ax.semilogx(freqs/1e3, amps, 'ko', markersize=10, markerfacecolor='none',
                linewidth=2, label='Measured data', zorder=5)
    ax.semilogx(f_model/1e3, H_schematic, 'b--', linewidth=2, alpha=0.5,
                label=f'Schematic model (fc={fc_schematic/1e3:.1f} kHz)')
    if rmse1 < 999:
        ax.semilogx(f_model/1e3, H_fit1, 'r-', linewidth=2,
                    label=f'Fit: 1 pole fixed (fc={fc1/1e3:.1f} kHz)')
    if rmse2 < 999:
        ax.semilogx(f_model/1e3, H_fit2, 'g-', linewidth=2,
                    label=f'Fit: 1 pole free (fc={fc2/1e3:.1f} kHz, G={gain2:.3f}V)')
    if rmse3 < 999:
        ax.semilogx(f_model/1e3, H_fit3, 'm-', linewidth=1.5,
                    label=f'Fit: 2 pole (fc1={fc3a/1e3:.1f}, fc2={fc3b/1e3:.0f} kHz)')
    ax.set_xlabel('Frequency (kHz)', fontsize=11)
    ax.set_ylabel('Output Amplitude (V peak)', fontsize=11)
    ax.set_title('Bode Magnitude — Amplitude', fontsize=12, fontweight='bold')
    ax.legend(fontsize=8, loc='lower left')
    ax.grid(True, which='both', alpha=0.3)
    ax.set_xlim([freqs[0]/1e3 * 0.7, freqs[-1]/1e3 * 1.5])

    # [0,1] Bode Magnitude — dB
    ax = axes[0, 1]
    ax.semilogx(freqs/1e3, gains_dB, 'ko', markersize=10, markerfacecolor='none',
                linewidth=2, label='Measured', zorder=5)
    H_sch_dB = 20*np.log10(H_schematic/INPUT_VPEAK)
    ax.semilogx(f_model/1e3, H_sch_dB, 'b--', linewidth=2, alpha=0.5,
                label=f'Schematic (fc={fc_schematic/1e3:.1f} kHz)')
    if rmse1 < 999:
        ax.semilogx(f_model/1e3, 20*np.log10(H_fit1/INPUT_VPEAK), 'r-', linewidth=2,
                    label=f'Fit 1-pole fixed (fc={fc1/1e3:.1f} kHz)')
    if rmse2 < 999:
        ax.semilogx(f_model/1e3, 20*np.log10(H_fit2/gain2), 'g-', linewidth=2,
                    label=f'Fit 1-pole free (fc={fc2/1e3:.1f} kHz)')
    ax.axhline(y=-3, color='gray', linestyle=':', alpha=0.6)
    ax.text(freqs[0]/1e3 * 0.8, -2.5, '-3 dB', fontsize=9, color='gray')
    ax.set_xlabel('Frequency (kHz)', fontsize=11)
    ax.set_ylabel('Gain (dB)', fontsize=11)
    ax.set_title('Bode Magnitude — dB (Normalized)', fontsize=12, fontweight='bold')
    ax.legend(fontsize=8, loc='lower left')
    ax.grid(True, which='both', alpha=0.3)
    ax.set_xlim([freqs[0]/1e3 * 0.7, freqs[-1]/1e3 * 1.5])
    ax.set_ylim([-15, 2])

    # [1,0] Residuals — how well does each model fit?
    ax = axes[1, 0]
    if rmse1 < 999:
        res1 = amps - model_1pole_fixed_gain(freqs, fc1)
        ax.plot(freqs/1e3, res1*1e3, 'ro-', markersize=6,
                label=f'1-pole fixed (RMSE={rmse1*1e3:.1f} mV)')
    if rmse2 < 999:
        res2 = amps - model_1pole(freqs, fc2, gain2)
        ax.plot(freqs/1e3, res2*1e3, 'gs-', markersize=6,
                label=f'1-pole free (RMSE={rmse2*1e3:.1f} mV)')
    if rmse3 < 999:
        res3 = amps - model_2pole(freqs, fc3a, fc3b, gain3)
        ax.plot(freqs/1e3, res3*1e3, 'm^-', markersize=6,
                label=f'2-pole (RMSE={rmse3*1e3:.1f} mV)')
    ax.axhline(y=0, color='k', linewidth=0.5)
    ax.set_xlabel('Frequency (kHz)', fontsize=11)
    ax.set_ylabel('Residual (mV)', fontsize=11)
    ax.set_title('Model Fit Residuals', fontsize=12, fontweight='bold')
    ax.legend(fontsize=9)
    ax.grid(True, alpha=0.3)

    # [1,1] Schematic comparison — overlay measured vs predicted
    ax = axes[1, 1]
    # Normalize both to their respective DC values for shape comparison
    if len(amps) > 0 and amps[0] > 0:
        ax.semilogx(freqs/1e3, amps/amps[0], 'ko', markersize=10,
                    markerfacecolor='none', linewidth=2, label='Measured (normalized)', zorder=5)
    ax.semilogx(f_model/1e3, H_schematic/H_schematic[0], 'b--', linewidth=2,
                alpha=0.7, label=f'Schematic: fc={fc_schematic/1e3:.1f} kHz (2700pF)')
    if fc2 > 0:
        C_eff = 1 / (2*np.pi*SCHEMATIC_R*fc2)
        H_measured_fit = 1/np.sqrt(1 + (f_model/fc2)**2)
        ax.semilogx(f_model/1e3, H_measured_fit, 'g-', linewidth=2,
                    label=f'Measured fit: fc={fc2/1e3:.1f} kHz ({C_eff*1e12:.0f}pF effective)')
    ax.axhline(y=1/np.sqrt(2), color='gray', linestyle=':', alpha=0.6)
    ax.text(freqs[-1]/1e3 * 1.1, 1/np.sqrt(2) + 0.02, '-3 dB', fontsize=9, color='gray')
    ax.set_xlabel('Frequency (kHz)', fontsize=11)
    ax.set_ylabel('Normalized Gain', fontsize=11)
    ax.set_title('Schematic Prediction vs Measured\n(Is the 2700pF cap the cause?)',
                 fontsize=12, fontweight='bold')
    ax.legend(fontsize=9)
    ax.grid(True, which='both', alpha=0.3)
    ax.set_xlim([freqs[0]/1e3 * 0.7, freqs[-1]/1e3 * 1.5])
    ax.set_ylim([0, 1.1])

    plt.tight_layout(rect=[0, 0, 1, 0.93])

    # Save
    png_path = os.path.join(SAVE_DIR, "sysid_bode_plot.png")
    plt.savefig(png_path, dpi=150, bbox_inches='tight')
    print(f"  Bode plot saved: {png_path}")
    plt.show()

    # ── Save results to files ──
    # JSON for easy reading
    json_path = os.path.join(SAVE_DIR, "sysid_results.json")
    json_data = {
        'input_vpp': INPUT_VPP,
        'sample_rate': FS,
        'measurements': results,
        'fits': {
            'single_pole_fixed': {
                'fc_Hz': float(fc1), 'fc_err_Hz': float(fc1_err),
                'rmse_V': float(rmse1)
            },
            'single_pole_free': {
                'fc_Hz': float(fc2), 'fc_err_Hz': float(fc2_err),
                'gain_V': float(gain2), 'rmse_V': float(rmse2)
            },
            'two_pole': {
                'fc1_Hz': float(fc3a), 'fc1_err_Hz': float(fc3a_err),
                'fc2_Hz': float(fc3b), 'fc2_err_Hz': float(fc3b_err),
                'gain_V': float(gain3), 'rmse_V': float(rmse3)
            },
            'schematic_prediction': {
                'fc_Hz': float(fc_schematic),
                'R_ohm': SCHEMATIC_R, 'C_pF': SCHEMATIC_C * 1e12
            }
        }
    }
    with open(json_path, 'w') as f:
        json.dump(json_data, f, indent=2)
    print(f"  Results JSON saved: {json_path}")

    # MAT file for MATLAB
    mat_path = os.path.join(SAVE_DIR, "sysid_results.mat")
    savemat(mat_path, {
        'freqs_Hz': freqs,
        'amplitude_V': amps,
        'gain_ratio': ratios,
        'gain_dB': gains_dB,
        'fit_fc1_Hz': fc1,
        'fit_fc2_Hz': fc2,
        'fit_gain2_V': gain2,
        'schematic_fc_Hz': fc_schematic,
        'input_vpeak': INPUT_VPEAK,
        'sample_rate': FS,
    })
    print(f"  Results MAT saved: {mat_path}")

    return json_data


# ════════════════════════════════════════════════════════════
#  ENTRY POINT
# ════════════════════════════════════════════════════════════

if __name__ == '__main__':

    # Check if we already have data (for re-analysis without re-capturing)
    json_path = os.path.join(SAVE_DIR, "sysid_results.json")
    if os.path.exists(json_path):
        print()
        print(f"  Previous sweep data found: {json_path}")
        choice = input("  [R]e-analyze existing data or [N]ew sweep? (R/N): ").strip().upper()
        if choice == 'R':
            with open(json_path, 'r') as f:
                saved = json.load(f)
            results = saved['measurements']
            print(f"  Loaded {len(results)} measurement points.")
            analyze_sweep(results)
            print("\n  Done. Close plot window to exit.")
            sys.exit(0)

    # New sweep
    results = collect_sweep_data(SWEEP_FREQS)
    analyze_sweep(results)
    print("\n  Done. Close plot window to exit.")
