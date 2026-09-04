#!/usr/bin/env python3

import json
import os
import socket
import subprocess
import sys

try:
    import requests
except ModuleNotFoundError:
    venv_python = "/opt/sdn-venv/bin/python3"
    if os.path.exists(venv_python) and sys.executable != venv_python:
        os.execv(venv_python, [venv_python] + sys.argv)
    else:
        print("[ERROR] 'requests' missing.", flush=True)
        sys.exit(1)

def get_host_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 1))
        ip = s.getsockname()[0]
    except Exception:
        ip = "127.0.0.1"
    finally:
        s.close()
    return ip

NAMESPACE = "micro-onos"
HOST_IP = get_host_ip()
NODE_PORT = 30181
TARGET_ENTITY = "devicesim-1"

GATEWAY_URL = f"http://{HOST_IP}:{NODE_PORT}/restconf/data/openconfig-system:system/clock/config"

HEADERS = {
    "Content-Type": "application/yang-data+json",
    "Accept": "application/yang-data+json",
}

def ensure_topology_entity():
    print(f"=== Provisioning Topology Entity '{TARGET_ENTITY}' ===")
    try:
        cli_cmd = f"kubectl get pods -n {NAMESPACE} -l app.kubernetes.io/name=onos-cli -o jsonpath='{{.items[0].metadata.name}}' 2>/dev/null || kubectl get pods -n {NAMESPACE} | grep onos-cli | head -n 1 | awk '{{print $1}}'"
        cli_pod = subprocess.check_output(cli_cmd, shell=True, text=True).strip()

        if cli_pod:
            print(f"[*] Cleaning up existing '{TARGET_ENTITY}'...")
            subprocess.run(
                f"kubectl exec -n {NAMESPACE} '{cli_pod}' -- onos topo delete entity {TARGET_ENTITY} 2>/dev/null",
                shell=True,
            )
            print(f"[*] Creating fresh '{TARGET_ENTITY}'...")
            subprocess.run(
                f"kubectl exec -n {NAMESPACE} '{cli_pod}' -- onos topo create entity {TARGET_ENTITY} --aspect onos.topo.Configurable='{{\"type\": \"devicesim\", \"version\": \"1.0.x\"}}'",
                shell=True,
                check=True,
            )
        else:
            print("[!] WARNING: Could not locate onos-cli pod. Skipping topo reset.")
    except Exception as e:
        print(f"[!] Topology setup warning: {e}")

def run_test():
    print("========================================")
    print(" RESTCONF Northbound Interface Test")
    print("========================================")
    print(f"[*] Gateway URL: {GATEWAY_URL}")
    print()

    ensure_topology_entity()

    print("\n========================================")
    print(" RESTCONF POST")
    print("========================================")
    print("[*] Setting system clock timezone to 'Europe/Paris'...")

    payload = {
        "openconfig-system:config": {
            "timezone-name": "Europe/Paris"
        }
    }

    try:
        response = requests.post(GATEWAY_URL, json=payload, headers=HEADERS, timeout=10)
        print(f"Status: {response.status_code}")
        if response.text:
            print(f"Body: {response.text}")
        if response.status_code not in (200, 201):
            return False
    except requests.RequestException as e:
        print(f"[ERROR] RESTCONF POST failed: {e}")
        return False

    print("\n========================================")
    print(" RESTCONF GET")
    print("========================================")
    print("[*] Reading system clock config...")

    try:
        get_response = requests.get(GATEWAY_URL, headers={"Accept": "application/yang-data+json"}, timeout=10)
        print(f"Status: {get_response.status_code}")
        if get_response.text:
            try:
                print("Body:", json.dumps(get_response.json(), indent=2))
            except ValueError:
                print(f"Body: {get_response.text}")
        if get_response.status_code != 200:
            return False
    except requests.RequestException as e:
        print(f"[ERROR] RESTCONF GET failed: {e}")
        return False

    return True

def main():
    if run_test():
        print("\n[OK] RESTCONF Northbound test completed successfully.")
        return 0
    print("\n[ERROR] RESTCONF Northbound test failed.")
    return 1

if __name__ == "__main__":
    sys.exit(main())
