#!/usr/bin/env python3

import json
import os
import socket
import sys

# Virtual environment auto-discovery fix
try:
    import requests
except ModuleNotFoundError:
    venv_python = "/opt/sdn-venv/bin/python3"
    if os.path.exists(venv_python) and sys.executable != venv_python:
        os.execv(venv_python, [venv_python] + sys.argv)
    else:
        print("[ERROR] 'requests' missing. Run bootstrap script or run with /opt/sdn-venv/bin/python3", flush=True)
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


HOST_IP = get_host_ip()
NODE_PORT = 30181
SERVICE_ID = "xc-100"

BASE_PATH = (
    "/restconf/data/"
    "controller-quantum-switching:quantum-services/"
    "cross-connect-service"
)

GATEWAY_URL = f"http://{HOST_IP}:{NODE_PORT}{BASE_PATH}"
SERVICE_URL = f"{GATEWAY_URL}={SERVICE_ID}"

payload = {
    "cross-connect-service": [
        {
            "service-id": SERVICE_ID,
            "target-node-ip": "192.168.100.5",
            "ingress-port": 10,
            "egress-port": 20,
            "admin-state": "ENABLED",
        }
    ]
}

HEADERS = {
    "Content-Type": "application/yang-data+json",
    "Accept": "application/yang-data+json",
}


def run_test():
    print("========================================")
    print(" RESTCONF Northbound Interface Test")
    print("========================================")
    print(f"[*] Gateway URL: {GATEWAY_URL}")
    print(f"[*] Service URL: {SERVICE_URL}")
    print(f"[*] Service ID:  {SERVICE_ID}")
    print()

    print("========================================")
    print(" RESTCONF POST")
    print("========================================")
    print(f"[*] Creating cross-connect '{SERVICE_ID}'...")

    try:
        response = requests.post(
            GATEWAY_URL, json=payload, headers=HEADERS, timeout=10
        )
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
    print(f"[*] Reading cross-connect '{SERVICE_ID}'...")

    try:
        get_response = requests.get(
            SERVICE_URL,
            headers={"Accept": "application/yang-data+json"},
            timeout=10,
        )
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
    success = run_test()
    if success:
        print("\n[OK] RESTCONF Northbound test completed successfully.")
        return 0

    print("\n[ERROR] RESTCONF Northbound test failed.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
