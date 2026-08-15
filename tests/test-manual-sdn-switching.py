#!/usr/bin/env python3
import sys
import os
import time

# --- ELEGANT VENV AUTO-DISCOVERY ---
try:
    import grpc
except ModuleNotFoundError:
    current_dir = os.path.dirname(os.path.abspath(__file__))
    venv_python = os.path.abspath(os.path.join(current_dir, '../.venv/bin/python3'))
    if os.path.exists(venv_python):
        os.execl(venv_python, venv_python, *sys.argv)
    else:
        print("[ERROR] 'grpc' missing and '.venv' not found. Run the bootstrap script first.")
        sys.exit(1)

# Import the client from the scripts folder
scripts_dir = os.path.abspath(os.path.join(current_dir, '../scripts'))
sys.path.append(scripts_dir)

client_module = __import__('sdn-switching-client')
QuantumSDNClient = client_module.QuantumSDNClient

def run_test(ip):
    print(f"\n--- Starting Automated Hardware Switching Test on {ip} ---")
    client = QuantumSDNClient(ip)
    
    print("\n[Step 1] Fetching initial status...")
    client.check_status()
    time.sleep(1)

    print("\n[Step 2] Triggering CONNECT...")
    client.set_connection(True)
    time.sleep(2)
    client.check_status()
    
    print("\n[Step 3] Triggering DISCONNECT...")
    client.set_connection(False)
    time.sleep(2)
    client.check_status()

    print("\n--- Test Sequence Complete ---\n")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python3 test-manual-sdn-switching.py <NODE_IP>")
        sys.exit(1)
    
    run_test(sys.argv[1])
