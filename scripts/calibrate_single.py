"""
calibrate_single.py — Multi-point DC calibration for ONE AD4630-24 channel at a time

Usage:
  1. Wire sig gen → one channel (IN+ via SMA, IN- → GND via alligator clip)
  2. Set CHANNEL below (0 or 1)
  3. Run script, step through DC voltages
  4. Repeat for the other channel with new wiring

Output: GAIN and OFFSET for the selected channel.
"""

import numpy as np
import paramiko
import os

# -- CONFIG --------------------------------------------------
CHANNEL = 1              # <<< SET THIS: 0 for Ch0, 1 for Ch1

ZED_IP   = "192.168.1.100"
ZED_USER = "root"
ZED_PASS = os.environ.get("ZED_PASS", "analog")   # from env var ZED_PASS; falls back to the stock ADI Kuiper default
FS       = 500000         # Match actual experiment rate
CAL_SAMPLES = 100000      # 0.2s
IIO_BUFFER_SIZE = 200000
REMOTE_BIN  = "/tmp/cal.bin"
LOCAL_BIN   = "E:\\DAQ Data\\_cal_temp.bin"


def ssh_connect():
    ssh = paramiko.SSHClient()
    # Trusted point-to-point link to a dedicated board at a fixed private
    # IP on an isolated segment, so auto-accepting its host key is fine
    # here. Use load_host_keys()/RejectPolicy on a shared network.
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(ZED_IP, username=ZED_USER, password=ZED_PASS, timeout=5)
    return ssh


def capture_and_pull(ssh, samples):
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
    ch0_diff = raw[:, 0] >> 8
    ch1_diff = raw[:, 1] >> 8
    return ch0_diff, ch1_diff


def fit_calibration(voltages, counts, label):
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
if __name__ == '__main__':
    ch_name  = f"Ch{CHANNEL}"
    in_plus  = "J2 (IN0+)" if CHANNEL == 0 else "J4 (IN1+)"
    in_minus = "J1 (IN0−)" if CHANNEL == 0 else "J3 (IN1−)"

    print("=" * 60)
    print(f"  DC CALIBRATION — {ch_name}")
    print("=" * 60)
    print()
    print(f"  Wiring:")
    print(f"    Sig gen BNC → SMA adapter → SMA cable → {in_plus}")
    print(f"    SMA cable → {in_minus}, center pin → alligator clip → GND barrel")
    print(f"    Other channel: LEAVE OPEN")
    print()
    print(f"  Set sig gen to DC mode, Hi-Z.")
    print(f"  Recommended voltages: -4, -3, -2, -1, 0, 1, 2, 3, 4 V")
    print("=" * 60)
    print()

    ssh = ssh_connect()

    voltages    = []
    active_means = []
    idle_means   = []

    print("Enter DC voltages one at a time. Type 'done' when finished.\n")

    while True:
        entry = input("  Set DC voltage (or 'done'): ").strip()
        if entry.lower() == 'done':
            break
        try:
            v_applied = float(entry)
        except ValueError:
            print("    Invalid number, try again.")
            continue

        input(f"    Confirm sig gen set to {v_applied:.3f}V DC, then press Enter...")

        ch0, ch1 = capture_and_pull(ssh, CAL_SAMPLES)

        if CHANNEL == 0:
            active, idle = ch0, ch1
        else:
            active, idle = ch1, ch0

        m_act, s_act = np.mean(active), np.std(active)
        m_idl, s_idl = np.mean(idle), np.std(idle)

        voltages.append(v_applied)
        active_means.append(m_act)
        idle_means.append(m_idl)

        print(f"    {ch_name} (active): mean={m_act:.1f}, std={s_act:.1f} counts")
        print(f"    Ch{1-CHANNEL} (idle):   mean={m_idl:.1f}, std={s_idl:.1f} counts")
        print()

    ssh.close()

    if len(voltages) < 2:
        print("Need at least 2 points. Exiting.")
        exit()

    print()
    print("=" * 60)
    print("  CALIBRATION RESULTS")
    print("=" * 60)

    G, O, R2 = fit_calibration(voltages, active_means, ch_name)

    print()
    print("=" * 60)
    print(f"  SUMMARY — Copy into sweep script:")
    print("=" * 60)
    print(f"  GAIN_{ch_name.upper()}   = {G:.10f}")
    print(f"  OFFSET_{ch_name.upper()} = {O:.6f}")
    print()

    try:
        os.remove(LOCAL_BIN)
    except Exception:
        pass
