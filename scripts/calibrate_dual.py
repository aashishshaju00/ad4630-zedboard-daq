"""
calibrate_dual.py — Multi-point DC calibration for BOTH AD4630-24 channels

Procedure:
  1. Wire sig gen Ch1 output → AD4630 Ch0 (BNC→SMA on IN0+, IN0- to GND)
  2. Wire sig gen Ch2 output → AD4630 Ch1 (BNC→SMA on IN1+, IN1- to GND)
  3. Set BOTH sig gen channels to DC mode, same voltage
  4. Step through voltages, script captures both channels simultaneously

Output: GAIN and OFFSET for each channel independently.
"""

import numpy as np
import paramiko
import os

# ===================================================================
#   USER CONFIG                                                      
# ===================================================================
ZED_IP   = "192.168.1.100"
ZED_USER = "root"
ZED_PASS = os.environ.get("ZED_PASS", "analog")   # from env var ZED_PASS; falls back to the stock ADI Kuiper default
FS       = 500000           # use the same rate as the actual experiments
CAL_SAMPLES = 100000        # 0.2s — plenty for averaging
IIO_BUFFER_SIZE = 200000
REMOTE_BIN  = "/tmp/cal.bin"
LOCAL_BIN   = r"E:\DAQ Data\_cal_temp.bin"


def ssh_connect():
    ssh = paramiko.SSHClient()
    # Trusted point-to-point link to a dedicated board at a fixed private
    # IP on an isolated segment, so auto-accepting its host key is fine
    # here. Use load_host_keys()/RejectPolicy on a shared network.
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(ZED_IP, username=ZED_USER, password=ZED_PASS, timeout=5)
    return ssh


def capture_and_pull(ssh, samples):
    """Capture both channels, return (ch0_diff, ch1_diff) as raw counts."""
    cmd = (
        f"iio_attr -u local: -d ad4630-24 sampling_frequency {FS} && "
        f"iio_readdev -u local: -b {min(samples, IIO_BUFFER_SIZE)} "
        f"-s {samples} ad4630-24 > {REMOTE_BIN}"
    )
    stdin, stdout, stderr = ssh.exec_command(cmd)
    stdout.channel.recv_exit_status()
    sftp = ssh.open_sftp()
    sftp.get(REMOTE_BIN, LOCAL_BIN)
    sftp.close()

    raw = np.fromfile(LOCAL_BIN, dtype=np.int32).reshape(-1, 2)
    ch0_diff = raw[:, 0] >> 8          # signed 24-bit differential
    ch1_diff = raw[:, 1] >> 8          # Ch1: same layout
    return ch0_diff, ch1_diff


def fit_calibration(voltages, counts, label):
    """Linear regression: V = GAIN * count + OFFSET"""
    voltages = np.array(voltages)
    counts   = np.array(counts)
    n = len(voltages)

    coeffs = np.polyfit(counts, voltages, 1)
    GAIN   = coeffs[0]
    OFFSET = coeffs[1]

    v_pred    = GAIN * counts + OFFSET
    residuals = voltages - v_pred
    ss_res    = np.sum(residuals**2)
    ss_tot    = np.sum((voltages - np.mean(voltages))**2)
    r_squared = 1 - ss_res / ss_tot if ss_tot > 0 else float('nan')

    se_residual = np.sqrt(ss_res / (n - 2)) if n > 2 else float('nan')
    count_mean  = np.mean(counts)
    ss_counts   = np.sum((counts - count_mean)**2)
    se_gain     = se_residual / np.sqrt(ss_counts) if ss_counts > 0 else float('nan')
    se_offset   = se_residual * np.sqrt(1/n + count_mean**2 / ss_counts) if ss_counts > 0 else float('nan')

    print(f"\n  -- {label} --")
    print(f"  GAIN:       {GAIN:.10f} V/count  (± {se_gain:.2e})")
    print(f"  OFFSET:     {OFFSET:.6f} V         (± {se_offset:.2e})")
    print(f"  R²:         {r_squared:.10f}")
    print(f"  Residual σ: {np.std(residuals)*1000:.3f} mV")
    print(f"  Point-by-point:")
    print(f"  {'Applied':>10}  {'Mean Count':>12}  {'Predicted':>10}  {'Residual':>10}")
    for i in range(n):
        print(f"  {voltages[i]:>10.3f}V  {counts[i]:>12.1f}  {v_pred[i]:>10.4f}V  {residuals[i]*1000:>+9.3f}mV")

    return GAIN, OFFSET, r_squared


# ============================================================
#  MAIN
# ============================================================
if __name__ == '__main__':
    print("=" * 60)
    print("  DUAL-CHANNEL DC CALIBRATION (Ch0 + Ch1)")
    print("=" * 60)
    print()
    print("  Wiring:")
    print("    Sig gen Ch1 → AD4630 Ch0 (IN0+), IN0- → GND")
    print("    Sig gen Ch2 → AD4630 Ch1 (IN1+), IN1- → GND")
    print()
    print("  Set BOTH sig gen channels to DC mode.")
    print("  Set BOTH to the SAME voltage at each step.")
    print("  Both channels should be in Hi-Z mode.")
    print()
    print("  Recommended voltages: -4, -3, -2, -1, 0, 1, 2, 3, 4 V")
    print("=" * 60)
    print()

    ssh = ssh_connect()

    voltages  = []
    ch0_means = []
    ch1_means = []

    print("Enter DC voltages one at a time. Type 'done' when finished.\n")

    while True:
        entry = input("  Set BOTH channels to DC voltage (or 'done'): ").strip()
        if entry.lower() == 'done':
            break
        try:
            v_applied = float(entry)
        except ValueError:
            print("    Invalid number, try again.")
            continue

        input(f"    Confirm BOTH channels set to {v_applied:.3f}V DC, then press Enter...")

        ch0, ch1 = capture_and_pull(ssh, CAL_SAMPLES)
        m0, s0 = np.mean(ch0), np.std(ch0)
        m1, s1 = np.mean(ch1), np.std(ch1)

        voltages.append(v_applied)
        ch0_means.append(m0)
        ch1_means.append(m1)
        print(f"    Ch0: mean={m0:.1f}, std={s0:.1f} counts")
        print(f"    Ch1: mean={m1:.1f}, std={s1:.1f} counts")
        print()

    ssh.close()

    if len(voltages) < 2:
        print("Need at least 2 points. Exiting.")
        exit()

    # -- Fit both channels --
    print()
    print("=" * 60)
    print("  CALIBRATION RESULTS")
    print("=" * 60)

    g0, o0, r0 = fit_calibration(voltages, ch0_means, "CH0")
    g1, o1, r1 = fit_calibration(voltages, ch1_means, "CH1")

    print()
    print("=" * 60)
    print("  SUMMARY — Copy into sweep script:")
    print("=" * 60)
    print(f"  GAIN_CH0   = {g0:.10f}")
    print(f"  OFFSET_CH0 = {o0:.6f}")
    print(f"  GAIN_CH1   = {g1:.10f}")
    print(f"  OFFSET_CH1 = {o1:.6f}")
    print()

    # -- Quick AFE sanity check --
    # At 0V DC, the offset difference tells us about AFE mismatch
    if 0.0 in voltages:
        idx = voltages.index(0.0)
        print(f"  AFE offset diff at 0V: {(g0*ch0_means[idx]+o0 - (g1*ch1_means[idx]+o1))*1000:.2f} mV")

    # Clean up
    try:
        os.remove(LOCAL_BIN)
    except Exception:
        pass
