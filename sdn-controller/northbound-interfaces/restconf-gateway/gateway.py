import os
import subprocess
import json
from flask import Flask, request, jsonify

app = Flask(__name__)

GNMI_TARGET = os.getenv("GNMI_TARGET", "onos-config.micro-onos.svc.cluster.local:5150")
DEFAULT_TARGET_DEVICE = os.getenv("GNMI_TARGET_DEVICE", "devicesim-1")
TLS_CERT = os.getenv("TLS_CERT", "/etc/onos/certs/tls.crt")
TLS_KEY = os.getenv("TLS_KEY", "/etc/onos/certs/tls.key")

def get_gnmic_base_cmd():
    cmd = ["gnmic", "-a", GNMI_TARGET, "--skip-verify"]
    if os.path.exists(TLS_CERT) and os.path.exists(TLS_KEY):
        cmd.extend(["--tls-cert", TLS_CERT, "--tls-key", TLS_KEY])
    return cmd

@app.route('/restconf/data/openconfig-system:system/clock/config', methods=['POST', 'PUT'])
def update_clock_config():
    payload = request.json or {}
    target_device = request.args.get("target", DEFAULT_TARGET_DEVICE)
    
    config = payload.get("openconfig-system:config", payload.get("config", {}))
    tz_name = config.get("timezone-name", "Europe/Paris")

    gnmi_path = "/system/clock/config/timezone-name"

    cmd = get_gnmic_base_cmd() + [
        "--target", target_device,
        "set",
        "--update", f"{gnmi_path}:::string:::{tz_name}"
    ]

    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        return jsonify({"error": "gNMI Set failed", "details": result.stderr}), 500

    return jsonify({
        "status": "Success",
        "target": target_device,
        "timezone-name": tz_name
    }), 201

@app.route('/restconf/data/openconfig-system:system/clock/config', methods=['GET'])
def get_clock_config():
    target_device = request.args.get("target", DEFAULT_TARGET_DEVICE)
    gnmi_path = "/system/clock/config/timezone-name"

    cmd = get_gnmic_base_cmd() + [
        "--target", target_device,
        "get",
        "--path", gnmi_path
    ]

    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        return jsonify({"error": "gNMI Get failed", "details": result.stderr}), 500

    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError:
        data = result.stdout

    return jsonify({"clock-config": data}), 200

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8181)
