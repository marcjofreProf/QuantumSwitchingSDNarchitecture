#!/usr/bin/env python3
import sys
import os
import time
import subprocess

# --- ELEGANT VENV AUTO-DISCOVERY ---
try:
    import ncclient
except ModuleNotFoundError:
    current_dir = os.path.dirname(os.path.abspath(__file__))
    venv_python = os.path.abspath(os.path.join(current_dir, '../.venv/bin/python3'))
    if os.path.exists(venv_python):
        os.execl(venv_python, venv_python, *sys.argv)
    else:
        print("[ERROR] 'ncclient' missing and '.venv' not found. Run the bootstrap script first.")
        sys.exit(1)

current_dir = os.path.dirname(os.path.abspath(__file__))
script_path = os.path.abspath(os.path.join(current_dir, '../scripts/netconf-switching-client.py'))

def run_test(ip):
    print(f"\n--- Starting Automated NETCONF Hardware Switching Test on {ip} ---")
    
    print("\n[Step 1] Fetching initial status...")
    subprocess.run([sys.executable, script_path, ip, "status"])
    time.sleep(1)

    print("\n[Step 2] Triggering CONNECT...")
    subprocess.run([sys.executable, script_path, ip, "connect"])
    time.sleep(2)
    subprocess.run([sys.executable, script_path, ip, "status"])
    
    print("\n[Step 3] Triggering DISCONNECT...")
    subprocess.run([sys.executable, script_path, ip, "disconnect"])
    time.sleep(2)
    subprocess.run([sys.executable, script_path, ip, "status"])

    print("\n--- Test Sequence Complete ---\n")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python3 tests/test-manual-netconf-switching.py <NODE_IP>")
        sys.exit(1)
    
    run_test(sys.argv[1])
