import numpy as np
import paramiko
import os

ZED_IP   = "192.168.1.100"
ZED_USER = "root"
ZED_PASS = "analog"
FS       = 1000000
CAL_SAMPLES = 100000  # 0.1s per point — enough for good averaging
REMOTE_BIN  = "/tmp/cal.bin"
LOCAL_BIN   = "E:\\DAQ Data\\_cal_temp.bin"


def ssh_connect():
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(ZED_IP, username=ZED_USER, password=ZED_PASS, timeout=5)
    return ssh


def capture_and_pull(ssh, samples):
    cmd = f"iio_readdev -u local: -b {min(samples, 200000)} -s {samples} ad4630-24 > {REMOTE_BIN}"
    stdin, stdout, stderr = ssh.exec_command(cmd)
    stdout.channel.recv_exit_status()
    sftp = ssh.open_sftp()
    sftp.get(REMOTE_BIN, LOCAL_BIN)
    sftp.close()
    raw = np.fromfile(LOCAL_BIN, dtype=np.int32).reshape(-1, 2)
    ch0_diff = raw[:, 0] >> 8
    return ch0_diff


# ════════════════════════════════════════════════════════════
print("=" * 55)
print("  MULTI-POINT DC CALIBRATION")
print("  Set Siglent to DC mode.")
print("  You will enter voltages and press Enter to capture.")
print("=" * 55)
print()

ssh = ssh_connect()

voltages = []
counts   = []

print("Enter DC voltages one at a time. Type 'done' when finished.")
print("Recommended: -4, -3, -2, -1, 0, 1, 2, 3, 4 volts")
print()

while True:
    entry = input("  Set DC voltage (or 'done'): ").strip()
    if entry.lower() == 'done':
        break
    try:
        v_applied = float(entry)
    except ValueError:
        print("    Invalid number, try again.")
        continue

    input(f"    Confirm Siglent is set to {v_applied:.3f}V DC, then press Enter...")

    ch0 = capture_and_pull(ssh, CAL_SAMPLES)
    mean_count = np.mean(ch0)
    std_count  = np.std(ch0)

    voltages.append(v_applied)
    counts.append(mean_count)
    print(f"    Captured: mean={mean_count:.1f} counts, std={std_count:.1f} counts")
    print()

ssh.close()

if len(voltages) < 2:
    print("Need at least 2 points. Exiting.")
    exit()

# ── Least-squares linear regression ──
voltages = np.array(voltages)
counts   = np.array(counts)

# Fit: V = GAIN * count + OFFSET
coeffs = np.polyfit(counts, voltages, 1)
GAIN   = coeffs[0]
OFFSET = coeffs[1]

# Predictions and residuals
v_pred    = GAIN * counts + OFFSET
residuals = voltages - v_pred
ss_res    = np.sum(residuals**2)
ss_tot    = np.sum((voltages - np.mean(voltages))**2)
r_squared = 1 - ss_res / ss_tot

# Uncertainty (standard error of coefficients)
n = len(voltages)
se_residual = np.sqrt(ss_res / (n - 2)) if n > 2 else float('nan')
count_mean  = np.mean(counts)
ss_counts   = np.sum((counts - count_mean)**2)
se_gain     = se_residual / np.sqrt(ss_counts) if ss_counts > 0 else float('nan')
se_offset   = se_residual * np.sqrt(1/n + count_mean**2 / ss_counts) if ss_counts > 0 else float('nan')

# ── Results ──
print()
print("=" * 55)
print("  CALIBRATION RESULTS")
print("=" * 55)
print(f"  Points:     {n}")
print(f"  GAIN:       {GAIN:.10f} V/count  (± {se_gain:.2e})")
print(f"  OFFSET:     {OFFSET:.6f} V         (± {se_offset:.2e})")
print(f"  R²:         {r_squared:.10f}")
print(f"  Residual σ: {np.std(residuals)*1000:.3f} mV")
print()
print("  Point-by-point:")
print(f"  {'Applied':>10}  {'Mean Count':>12}  {'Predicted':>10}  {'Residual':>10}")
for i in range(n):
    print(f"  {voltages[i]:>10.3f}V  {counts[i]:>12.1f}  {v_pred[i]:>10.4f}V  {residuals[i]*1000:>+9.3f}mV")
print()
print(f"  Copy these into record_chrome.py:")
print(f"  GAIN   = {GAIN:.10f}")
print(f"  OFFSET = {OFFSET:.6f}")

# Clean up
try:
    os.remove(LOCAL_BIN)
except Exception:
    pass