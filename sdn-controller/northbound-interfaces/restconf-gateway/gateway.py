import os, subprocess, json
from flask import Flask, request, jsonify

app = Flask(__name__)

GNMI_TARGET = os.getenv("GNMI_TARGET", "onos-config.micro-onos.svc.cluster.local:5150")
DEFAULT_TARGET_DEVICE = os.getenv("GNMI_TARGET_DEVICE", "devicesim-1")
TLS_CERT = os.getenv("TLS_CERT", "/etc/onos/certs/tls.crt")
TLS_KEY = os.getenv("TLS_KEY", "/etc/onos/certs/tls.key")

CROSS_CONNECT_STORE = {}

def get_gnmic_base_cmd():
    cmd = ["gnmic", "-a", GNMI_TARGET, "--skip-verify"]
    if os.path.exists(TLS_CERT) and os.path.exists(TLS_KEY):
        cmd.extend(["--tls-cert", TLS_CERT, "--tls-key", TLS_KEY])
    return cmd

def dispatch_southbound_config(action, payload, sb_target):
    """Synchronously executes southbound config and returns execution status"""
    target_device = payload.get("target-node-ip", DEFAULT_TARGET_DEVICE)
    service_id = payload.get("service-id", "qservice")
    gnmi_path = f"/quantum-switching/cross-connect[id={service_id}]"
    
    if action == "DELETE":
        cmd = get_gnmic_base_cmd() + ["--target", target_device, "set", "--delete", gnmi_path]
    else:
        json_val = json.dumps(payload)
        cmd = get_gnmic_base_cmd() + ["--target", target_device, "set", "--update", f"{gnmi_path}:::json:::{json_val}"]

    # Synchronously capture returncode and stderr
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        return False, result.stderr
    return True, result.stdout

@app.route('/restconf/data/example-quantum-switching-terminal-service:quantum-services/cross-connect-service', methods=['POST', 'PUT'])
def create_cross_connect():
    payload = request.json or {}
    sb_target = request.headers.get("X-Southbound-Target", "NETCONF")
    
    # 1. Block and verify southbound execution
    success, details = dispatch_southbound_config("SET", payload, sb_target)
    if not success:
        return jsonify({"error": "Southbound device push failed", "details": details}), 502

    # 2. Update state only after confirmed southbound delivery
    CROSS_CONNECT_STORE["active"] = payload
    return jsonify({"status": "SUCCESS", "service": payload, "sb": sb_target}), 201

@app.route('/restconf/data/example-quantum-switching-terminal-service:quantum-services/cross-connect-service', methods=['GET'])
def get_cross_connect():
    if "active" not in CROSS_CONNECT_STORE:
        return jsonify({"error": "Not Found"}), 404
        
    return jsonify({
        "example-quantum-switching-terminal-service:cross-connect-service": [
            CROSS_CONNECT_STORE["active"]
        ]
    }), 200

@app.route('/restconf/data/example-quantum-switching-terminal-service:quantum-services/cross-connect-service', methods=['DELETE'])
def delete_cross_connect():
    sb_target = request.args.get("sb", "NETCONF")
    
    if "active" in CROSS_CONNECT_STORE:
        payload = CROSS_CONNECT_STORE.pop("active")
        success, details = dispatch_southbound_config("DELETE", payload, sb_target)
        if not success:
            return jsonify({"error": "Southbound device deletion failed", "details": details}), 502
        return jsonify({"status": "DELETED"}), 200
        
    return jsonify({"error": "Not Found"}), 404

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8181)
