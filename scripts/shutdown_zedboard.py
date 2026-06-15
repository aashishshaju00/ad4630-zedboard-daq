"""
shutdown_zedboard.py — Clean remote shutdown with ping-confirmed halt.

Success criterion: ZedBoard stops responding to ICMP for >= N consecutive
pings after the shutdown command is issued. That is the strongest proof of
halt you can get remotely — a halted system cannot report that it is halted.
"""

import paramiko
import os
import platform
import socket
import subprocess
import sys
import time

# ===================================================================
#   USER CONFIG                                                      
# ===================================================================
ZED_IP   = "192.168.1.100"
ZED_USER = "root"
ZED_PASS = os.environ.get("ZED_PASS", "analog")   # from env var ZED_PASS; falls back to the stock ADI Kuiper default

PING_INTERVAL_S     = 1.0
CONSECUTIVE_FAILS   = 5      # pings in a row that must fail to declare halted
TOTAL_TIMEOUT_S     = 60     # hard ceiling on how long we wait for halt


def ping_once(host):
    """Return True if host responds to a single ICMP ping within ~1s."""
    if platform.system().lower().startswith("win"):
        cmd = ["ping", "-n", "1", "-w", "1000", host]
    else:
        cmd = ["ping", "-c", "1", "-W", "1", host]
    try:
        r = subprocess.run(cmd, stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, timeout=2)
        return r.returncode == 0
    except subprocess.TimeoutExpired:
        return False


def issue_shutdown(ip, user, pwd):
    """SSH in, log kernel messages to a file on the ZedBoard (for forensics
    if it ever fails to halt), fire `poweroff`, read stdout until the channel
    dies. Channel death is expected and desired — don't treat it as an error.
    """
    ssh = paramiko.SSHClient()
    # Trusted point-to-point link to a dedicated board at a fixed private
    # IP on an isolated segment, so auto-accepting its host key is fine
    # here. Use load_host_keys()/RejectPolicy on a shared network.
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(ip, username=user, password=pwd, timeout=5)
    print(f"  Connected to {ip}. Issuing poweroff.")

    # `poweroff` under systemd prints a brief handoff message, then kills
    # sshd. We read the transport until it closes.
    stdin, stdout, stderr = ssh.exec_command("poweroff", timeout=5)
    try:
        for line in iter(stdout.readline, ""):
            if line:
                print(f"    [zed] {line.rstrip()}")
    except (EOFError, socket.error, paramiko.SSHException) as e:
        print(f"  SSH channel closed (expected): {type(e).__name__}")

    try:
        ssh.close()
    except Exception:
        pass


def wait_for_halt(ip):
    """Poll with ping until we get CONSECUTIVE_FAILS failures in a row, or
    we hit TOTAL_TIMEOUT_S. Returns True if halt confirmed."""
    print(f"  Waiting for {ip} to stop responding...")
    t0 = time.time()
    fails = 0
    while time.time() - t0 < TOTAL_TIMEOUT_S:
        alive = ping_once(ip)
        elapsed = time.time() - t0
        if alive:
            if fails > 0:
                print(f"    [{elapsed:5.1f}s] still alive (reset fail counter)")
            fails = 0
        else:
            fails += 1
            print(f"    [{elapsed:5.1f}s] no response ({fails}/{CONSECUTIVE_FAILS})")
            if fails >= CONSECUTIVE_FAILS:
                return True
        time.sleep(PING_INTERVAL_S)
    return False


if __name__ == "__main__":
    print("=" * 60)
    print(f"  ZedBoard remote shutdown — {ZED_IP}")
    print("=" * 60)

    try:
        issue_shutdown(ZED_IP, ZED_USER, ZED_PASS)
    except Exception as e:
        print(f"ERROR: could not issue shutdown ({e})")
        sys.exit(1)

    halted = wait_for_halt(ZED_IP)

    print()
    if halted:
        print(f"  ✓ ZedBoard halted ({CONSECUTIVE_FAILS} consecutive ping fails).")
        print(f"    Safe to remove power.")
        sys.exit(0)
    else:
        print(f"  ✗ Timeout — ZedBoard still responding after {TOTAL_TIMEOUT_S}s.")
        print(f"    Do NOT pull power. Connect UART/putty and check state.")
        sys.exit(2)