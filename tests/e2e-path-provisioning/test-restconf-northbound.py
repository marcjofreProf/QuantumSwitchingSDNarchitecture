#!/usr/bin/env python3

import json
import os
import subprocess
import sys
import time

# From the host controller:
#   python3 ./tests/e2e-path-provisioning/test-restconf-northbound.py

current_dir = os.path.dirname(os.path.abspath(__file__))

# ---------------------------------------------------------------------------
# VENV AUTO-DISCOVERY & RE-EXECUTION
# ---------------------------------------------------------------------------

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

    print(
        "[ERROR] 'requests' missing and no virtual environment found. "
        "Run bootstrap script first."
    )
    sys.exit(1)


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

NAMESPACE = "micro-onos"
SERVICE = "restconf-gateway"

LOCAL_PORT = 8181
REMOTE_PORT = 8181

SERVICE_ID = "xc-100"

BASE_PATH = (
    "/restconf/data/"
    "controller-quantum-switching:quantum-services/"
    "cross-connect-service"
)

GATEWAY_URL = f"http://127.0.0.1:{LOCAL_PORT}{BASE_PATH}"

SERVICE_URL = f"{GATEWAY_URL}={SERVICE_ID}"


# ---------------------------------------------------------------------------
# RESTCONF payload
# ---------------------------------------------------------------------------

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


# ---------------------------------------------------------------------------
# Kubernetes helpers
# ---------------------------------------------------------------------------

def check_service():
    """Verify that the RESTCONF gateway Service exists."""

    print(
        f"[*] Checking Kubernetes service "
        f"'{SERVICE}' in namespace '{NAMESPACE}'..."
    )

    result = subprocess.run(
        [
            "kubectl",
            "get",
            "svc",
            SERVICE,
            "-n",
            NAMESPACE,
        ],
        capture_output=True,
        text=True,
    )

    if result.returncode != 0:
        print(
            f"[ERROR] Kubernetes service '{SERVICE}' not found "
            f"in namespace '{NAMESPACE}'."
        )
        print(result.stderr.strip())
        sys.exit(1)


def start_port_forward():
    """Start kubectl port-forward and return the process."""

    print(
        f"[*] Starting RESTCONF port-forward: "
        f"localhost:{LOCAL_PORT} -> "
        f"{SERVICE}:{REMOTE_PORT}"
    )

    log_file = open("/tmp/restconf-gateway-port-forward.log", "w")

    process = subprocess.Popen(
        [
            "kubectl",
            "port-forward",
            "-n",
            NAMESPACE,
            f"svc/{SERVICE}",
            f"{LOCAL_PORT}:{REMOTE_PORT}",
        ],
        stdout=log_file,
        stderr=subprocess.STDOUT,
        text=True,
    )

    return process, log_file


def wait_for_port_forward(process):
    """Wait until the local RESTCONF port is accepting connections."""

    print("[*] Waiting for port-forward...")

    for _ in range(20):

        if process.poll() is not None:
            print("[ERROR] kubectl port-forward terminated.")

            try:
                with open(
                    "/tmp/restconf-gateway-port-forward.log",
                    "r",
                ) as f:
                    print(f.read())
            except Exception:
                pass

            sys.exit(1)

        # Use a simple TCP connection test.
        test = subprocess.run(
            [
                "bash",
                "-c",
                f"echo >/dev/tcp/127.0.0.1/{LOCAL_PORT}",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

        if test.returncode == 0:
            print("[*] RESTCONF port-forward is ready.")
            return

        time.sleep(0.5)

    print(
        f"[ERROR] RESTCONF port {LOCAL_PORT} did not become available."
    )
    sys.exit(1)


# ---------------------------------------------------------------------------
# RESTCONF test
# ---------------------------------------------------------------------------

def run_test():

    print()
    print("========================================")
    print(" RESTCONF Northbound Interface Test")
    print("========================================")
    print()

    print(f"[*] Gateway URL: {GATEWAY_URL}")
    print(f"[*] Service URL: {SERVICE_URL}")
    print(f"[*] Service ID:  {SERVICE_ID}")
    print()

    # -----------------------------------------------------------------------
    # POST
    # -----------------------------------------------------------------------

    print("========================================")
    print(" RESTCONF POST")
    print("========================================")

    print(f"[*] Creating cross-connect '{SERVICE_ID}'...")

    try:
        response = requests.post(
            GATEWAY_URL,
            json=payload,
            headers=HEADERS,
            timeout=10,
        )

        print(f"Status: {response.status_code}")

        if response.text:
            print(f"Body: {response.text}")

    except requests.RequestException as e:
        print(f"[ERROR] RESTCONF POST failed: {e}")
        return False

    # -----------------------------------------------------------------------
    # GET
    # -----------------------------------------------------------------------

    print()
    print("========================================")
    print(" RESTCONF GET")
    print("========================================")

    print(f"[*] Reading cross-connect '{SERVICE_ID}'...")

    try:
        get_response = requests.get(
            SERVICE_URL,
            headers={
                "Accept": "application/yang-data+json",
            },
            timeout=10,
        )

        print(f"Status: {get_response.status_code}")

        if get_response.text:
            try:
                print(
                    "Body:",
                    json.dumps(
                        get_response.json(),
                        indent=2,
                    ),
                )
            except ValueError:
                print(f"Body: {get_response.text}")

    except requests.RequestException as e:
        print(f"[ERROR] RESTCONF GET failed: {e}")
        return False

    return True


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():

    check_service()

    port_forward_process = None
    log_file = None

    try:
        port_forward_process, log_file = start_port_forward()

        wait_for_port_forward(port_forward_process)

        success = run_test()

        if success:
            print()
            print("[OK] RESTCONF Northbound test completed.")
            return 0

        print()
        print("[ERROR] RESTCONF Northbound test failed.")
        return 1

    finally:

        if port_forward_process is not None:
            print()
            print("[*] Stopping kubectl port-forward...")

            port_forward_process.terminate()

            try:
                port_forward_process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                port_forward_process.kill()

        if log_file is not None:
            log_file.close()


if __name__ == "__main__":
    sys.exit(main())
