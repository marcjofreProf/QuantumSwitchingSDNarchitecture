#!/usr/bin/env python3
import sys
import os
import subprocess
import json
# executoin as: python3 tests/e2e-path-provisioning/test-restconf-northbound.py
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
    print("[ERROR] 'requests' missing and no virtual environment found. Run bootstrap script first.")
    sys.exit(1)

def ensure_k3s_route():
    """Ensures host route to K3s ClusterIP network exists."""
    try:
        res = subprocess.run(["ip", "route"], capture_output=True, text=True)
        if "10.43.0.0/16" not in res.stdout:
            print("[*] K3s ClusterIP route missing. Injecting 10.43.0.0/16 via cni0...")
            subprocess.run(["sudo", "ip", "route", "add", "10.43.0.0/16", "dev", "cni0"], 
                           stderr=subprocess.DEVNULL, check=False)
    except Exception as e:
        print(f"[!] Warning: Could not check/inject K3s route: {e}")

def get_cluster_ip(service_name, namespace="micro-onos"):
    """Fetches internal Kubernetes ClusterIP using kubectl."""
    try:
        cmd = ["kubectl", "get", "svc", service_name, "-n", namespace, "-o", "jsonpath={.spec.clusterIP}"]
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        ip = result.stdout.strip()
        if not ip:
            raise ValueError("Empty IP returned")
        return ip
    except Exception as e:
        print(f"[ERROR] Could not resolve ClusterIP for '{service_name}' in namespace '{namespace}': {e}")
        sys.exit(1)

# Ensure routing is enabled before making calls
ensure_k3s_route()

# Dynamically target restconf-gateway ClusterIP
cluster_ip = get_cluster_ip("restconf-gateway")
GATEWAY_URL = f"http://{cluster_ip}:8181/restconf/data/controller-quantum-switching:quantum-services/cross-connect-service"

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
    print(f"[*] Target resolved to ClusterIP URL: {GATEWAY_URL}")
    print("Sending RESTCONF POST...")
    try:
        response = requests.post(GATEWAY_URL, json=payload, headers=headers, timeout=5)
        print(f"Status: {response.status_code}")
        print(f"Body: {response.text}")

        print("\nSending RESTCONF GET...")
        get_response = requests.get(f"{GATEWAY_URL}/xc-100", headers={"Accept": "application/yang-data+json"}, timeout=5)
        print(f"Status: {get_response.status_code}")
        try:
            print(f"Body: {json.dumps(get_response.json(), indent=2)}")
        except Exception:
            print(f"Body: {get_response.text}")
    except Exception as e:
        print(f"[ERROR] Connection to RESTCONF Gateway failed: {e}")

if __name__ == "__main__":
    run_test()
