import numpy as np
import paramiko
import time
from scipy.io import savemat
import os
import sys

from acquisition_io import (
    AcquisitionError,
    capture_frame_with_retry,
    cleanup_capture_resources,
    ensure_output_directory,
)

# ===================================================================
#   USER CONFIG — edit these for your setup                          
# ===================================================================

# -- Hardware / Network --------------------------------------
ZED_IP   = "192.168.1.100"
ZED_USER = "root"
ZED_PASS = os.environ.get("ZED_PASS", "analog")   # from env var ZED_PASS; falls back to the stock ADI Kuiper default

# -- ADC Calibration (FRESH — from calibrate_dual.py) --------
GAIN_CH0   = 0.0000006268
OFFSET_CH0 = -0.040402
GAIN_CH1   = 0.0000006355
OFFSET_CH1 = 0.000751

FS = 500000          # 500 kSPS

# -- Capture Settings ----------------------------------------
CAPTURE_SECONDS = 2      # seconds per capture
TOTAL_SAMPLES   = CAPTURE_SECONDS * FS
IIO_BUFFER_SIZE = 200000
REMOTE_BIN      = "/tmp/capture.bin"
CAPTURE_TIMEOUT_MARGIN_S = 15    # grace over CAPTURE_SECONDS before a capture is abandoned
MAX_CAPTURE_RETRIES      = 2     # extra attempts per rep before aborting the sweep

# -- Save Directory ------------------------------------------
SAVE_DIR = "E:\\DAQ Data\\Data_files\\sysid_final\\"

# -- Sweep Configuration -------------------------------------
INPUT_VPP   = 4.0                # Siglent setting (Vpp)
INPUT_VPEAK = INPUT_VPP / 2.0    # Peak voltage
N_REPEATS   = 3                  # captures per frequency

# Same 24-point grid as original sysid (source of truth)
SWEEP_FREQS = [1000, 5000, 10000, 15000, 20000, 25000,
               30000, 33000, 36000, 39000, 42000, 45000,
               50000, 53000, 60000, 65000, 70000, 75000,
               85000, 90000, 95000, 100000, 110000, 120000]

# Settle time after frequency change (seconds)
SETTLE_SECONDS = 0.3


# ============================================================
#  HARDWARE HELPERS
# ============================================================

def ssh_connect():
    ssh = paramiko.SSHClient()
    # Trusted point-to-point link to a dedicated board at a fixed private
    # IP on an isolated segment, so auto-accepting its host key is fine
    # here. Use load_host_keys()/RejectPolicy on a shared network.
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(ZED_IP, username=ZED_USER, password=ZED_PASS, timeout=5)
    return ssh

# Capture / transfer / parse now come from acquisition_io (shared, failure-safe,
# unit-tested). ssh_connect stays here because it owns this script's credentials.


# ============================================================
#  MAIN — PER-CHANNEL SYSID SWEEP (two passes: Ch0, then Ch1)
# ============================================================

if __name__ == '__main__':

    ensure_output_directory(SAVE_DIR)
    local_bin = os.path.join(SAVE_DIR, "_sweep_temp.bin")
    n_freqs = len(SWEEP_FREQS)

    print()
    print("=" * 65)
    print("  PER-CHANNEL SYSID — FINAL CALIBRATION")
    print("=" * 65)
    print()
    print("  This script runs TWO passes:")
    print("    Pass 1: Ch0 only (sig gen → J2/IN0+, J1/IN0− → GND)")
    print("    Pass 2: Ch1 only (sig gen → J4/IN1+, J3/IN1− → GND)")
    print()
    print(f"  Frequencies:  {n_freqs} points, "
          f"{SWEEP_FREQS[0]/1e3:.0f}–{SWEEP_FREQS[-1]/1e3:.0f} kHz")
    print(f"  Repeats:      {N_REPEATS} per frequency")
    print(f"  Capture:      {CAPTURE_SECONDS}s per tone @ {FS/1e3:.0f} kSPS")
    print(f"  Samples:      {TOTAL_SAMPLES:,} per capture")
    print(f"  Output dir:   {SAVE_DIR}")
    print()
    print(f"  Siglent settings (constant throughout):")
    print(f"    Amplitude:  {INPUT_VPP} Vpp, Sine, Hi-Z, Output ON")
    print()

    # -- Connect to ZedBoard --
    try:
        ssh = ssh_connect()
        print("  ZedBoard connected.")
    except Exception as e:
        print(f"ERROR: Cannot connect to ZedBoard ({e})")
        sys.exit(1)

    # ========================================================
    #  RUN BOTH PASSES
    # ========================================================

    for ch_idx in [0, 1]:
        ch_name = f"Ch{ch_idx}"
        in_plus  = "J2 (IN0+)" if ch_idx == 0 else "J4 (IN1+)"
        in_minus = "J1 (IN0−)" if ch_idx == 0 else "J3 (IN1−)"

        print()
        print("=" * 65)
        print(f"  PASS {ch_idx + 1}/2 — {ch_name} SYSID")
        print("=" * 65)
        print()
        print(f"  Wiring:")
        print(f"    Sig gen BNC → SMA adapter → SMA cable → {in_plus}")
        print(f"    SMA cable → {in_minus}, center pin → alligator clip → GND barrel")
        print(f"    Other channel SMA jacks: LEAVE OPEN (nothing connected)")
        print()
        input(f"  >>> Press ENTER when {ch_name} wiring is ready... ")
        print()

        # Preallocate for this channel pass
        # Store both ADC channels even though only one has signal —
        # the idle channel serves as a noise/crosstalk check
        all_ch0 = np.zeros((TOTAL_SAMPLES, n_freqs, N_REPEATS), dtype=np.int32)
        all_ch1 = np.zeros((TOTAL_SAMPLES, n_freqs, N_REPEATS), dtype=np.int32)

        for i, freq in enumerate(SWEEP_FREQS):
            freq_khz = freq / 1e3
            print(f"  [{i+1}/{n_freqs}] Set Siglent to {freq_khz:.1f} kHz")
            input(f"       >>> Press ENTER when frequency is set... ")

            if SETTLE_SECONDS > 0:
                time.sleep(SETTLE_SECONDS)

            for rep in range(N_REPEATS):
                sys.stdout.write(f"       Rep {rep+1}/{N_REPEATS}: capturing... ")
                sys.stdout.flush()

                def _note_retry(attempt, exc):
                    sys.stdout.write(f"\n       attempt {attempt} failed ({exc}); "
                                     f"retrying... ")
                    sys.stdout.flush()

                t0 = time.time()
                try:
                    ch0_raw, ch1_raw = capture_frame_with_retry(
                        ssh, TOTAL_SAMPLES, IIO_BUFFER_SIZE, FS,
                        REMOTE_BIN, local_bin,
                        CAPTURE_SECONDS + CAPTURE_TIMEOUT_MARGIN_S,
                        max_retries=MAX_CAPTURE_RETRIES,
                        on_retry=_note_retry,
                    )
                except AcquisitionError as exc:
                    print(f"\n  ERROR: {freq_khz:.1f} kHz rep {rep+1} failed after "
                          f"{MAX_CAPTURE_RETRIES + 1} attempts: {exc}")
                    for warning in cleanup_capture_resources(ssh, REMOTE_BIN, local_bin):
                        print(f"  Cleanup warning: {warning}")
                    sys.exit(1)
                t_elapsed = time.time() - t0

                # Length is guaranteed == TOTAL_SAMPLES by the strict parse.
                all_ch0[:, i, rep] = ch0_raw
                all_ch1[:, i, rep] = ch1_raw

                # Quick sanity: RMS of the ACTIVE channel
                if ch_idx == 0:
                    rms_active = np.sqrt(np.mean(ch0_raw.astype(np.float64)**2))
                    rms_idle   = np.sqrt(np.mean(ch1_raw.astype(np.float64)**2))
                else:
                    rms_active = np.sqrt(np.mean(ch1_raw.astype(np.float64)**2))
                    rms_idle   = np.sqrt(np.mean(ch0_raw.astype(np.float64)**2))

                print(f"done ({t_elapsed:.1f}s)  "
                      f"Active RMS={rms_active:.0f}  Idle RMS={rms_idle:.0f}")

            print()

        # -- Save this pass --
        mat_name = f"sysid_final_ch{ch_idx}.mat"
        mat_path = os.path.join(SAVE_DIR, mat_name)
        print(f"  Saving {mat_path} ...")
        sys.stdout.flush()

        savemat(mat_path, {
            # Raw waveforms: (n_samples × n_freqs × n_repeats), int32
            'ch0_raw':          all_ch0,
            'ch1_raw':          all_ch1,

            # Which channel was driven
            'active_channel':   np.float64(ch_idx),

            # Frequency vector (Hz)
            'freqs_Hz':         np.array(SWEEP_FREQS, dtype=np.float64),

            # Metadata
            'sample_rate':      np.float64(FS),
            'capture_seconds':  np.float64(CAPTURE_SECONDS),
            'n_samples':        np.float64(TOTAL_SAMPLES),
            'n_freqs':          np.float64(n_freqs),
            'n_repeats':        np.float64(N_REPEATS),
            'input_vpp':        np.float64(INPUT_VPP),

            # ADC calibration
            'gain_ch0':         np.float64(GAIN_CH0),
            'offset_ch0':       np.float64(OFFSET_CH0),
            'gain_ch1':         np.float64(GAIN_CH1),
            'offset_ch1':       np.float64(OFFSET_CH1),
        }, do_compression=True)

        fsize = os.path.getsize(mat_path) / 1e6
        print(f"  Saved: {mat_name}  ({fsize:.0f} MB)")

        # Free memory before next pass
        del all_ch0, all_ch1

    # -- Cleanup --
    for warning in cleanup_capture_resources(ssh, REMOTE_BIN, local_bin):
        print(f"  Cleanup warning: {warning}")

    print()
    print("=" * 65)
    print("  COLLECTION COMPLETE — BOTH CHANNELS")
    print(f"  Output files:")
    print(f"    {SAVE_DIR}sysid_final_ch0.mat")
    print(f"    {SAVE_DIR}sysid_final_ch1.mat")
    print()
    print(f"  Each file contains:")
    print(f"    ch0_raw, ch1_raw: ({TOTAL_SAMPLES} × {n_freqs} × {N_REPEATS})")
    print(f"    active_channel:   which channel had signal")
    print(f"    freqs_Hz:         frequency vector")
    print()
    print(f"  Next: run sysid_analysis_dual.m in MATLAB")
    print("=" * 65)
