#!/usr/bin/env python3
import sys
import os

current_dir = os.path.dirname(os.path.abspath(__file__))

# --- VENV AUTO-DISCOVERY & RE-EXECUTION ---
try:
    import requests
except ModuleNotFoundError:
    venv_candidates = [
        "/opt/sdn-venv/bin/python3",
        os.path.abspath(os.path.join(current_dir, "../../.venv/bin/python3")),
        os.path.abspath(os.path.join(current_dir, "../.venv/bin/python3")),
    ]
    for venv_python in venv_candidates:
        if os.path.exists(venv_python):
            os.execl(venv_python, venv_python, *sys.argv)
    print("[ERROR] 'requests' missing and no virtual environment found. Run the bootstrap script first.")
    sys.exit(1)

import json

# Targets the exposed RESTCONF Gateway (Tries port 8181 first, falls back to NodePort 30181)
GATEWAY_URL = "http://localhost:8181/restconf/data/controller-quantum-switching:quantum-services/cross-connect-service"
ALT_GATEWAY_URL = "http://localhost:30181/restconf/data/controller-quantum-switching:quantum-services/cross-connect-service"

payload = {
    "cross-connect-service": [{
        "service-id": "xc-100",
        "target-node-ip": "192.168.100.5",
        "ingress-port": 10,
        "egress-port": 20,
        "admin-state": "ENABLED"
    }]
}

headers = {
    "Content-Type": "application/yang-data+json",
    "Accept": "application/yang-data+json"
}

def run_test():
    target_url = GATEWAY_URL
    try:
        requests.get("http://localhost:8181/", timeout=2)
    except Exception:
        target_url = ALT_GATEWAY_URL

    print(f"[*] Sending RESTCONF POST to {target_url}...")
    try:
        response = requests.post(target_url, json=payload, headers=headers, timeout=5)
        print(f"Status: {response.status_code}")
        print(f"Body: {response.text}")

        print("\n[*] Sending RESTCONF GET...")
        get_response = requests.get(f"{target_url}/xc-100", headers={"Accept": "application/yang-data+json"}, timeout=5)
        print(f"Status: {get_response.status_code}")
        try:
            print(f"Body: {json.dumps(get_response.json(), indent=2)}")
        except Exception:
            print(f"Body: {get_response.text}")
    except Exception as e:
        print(f"[ERROR] RESTCONF Gateway request failed: {e}")

if __name__ == "__main__":
    run_test()
