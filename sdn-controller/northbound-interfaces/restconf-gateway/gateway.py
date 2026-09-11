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
    # Handle RESTCONF list wrapper if present
    if isinstance(payload, dict) and "cross-connect-service" in payload:
        items = payload["cross-connect-service"]
        data = items[0] if isinstance(items, list) and items else {}
    else:
        data = payload if isinstance(payload, dict) else {}

    target_device = data.get("target-node") or data.get("target-node-ip") or DEFAULT_TARGET_DEVICE
    service_id = data.get("service-id", "qservice")
    ingress_port = data.get("ingress-port", 1)
    if_name = f"eth{ingress_port}"

    if action == "DELETE":
        cmd = get_gnmic_base_cmd() + [
            "--target", target_device,
            "set",
            "--delete", f"/interfaces/interface[name={if_name}]"
        ]
    else:
        # Use explicit OpenConfig paths instead of direct interface JSON injection
        cmd = get_gnmic_base_cmd() + [
            "--target", target_device,
            "set",
            "--update", f"/interfaces/interface[name={if_name}]/config/description:::string:::{service_id}",
            "--update", f"/interfaces/interface[name={if_name}]/config/enabled:::bool:::true"
        ]

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
        if result.returncode != 0:
            return False, result.stderr
        return True, result.stdout
    except subprocess.TimeoutExpired:
        return False, "gnmic request to onos-config timed out after 5s"

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
    if "active" not in CROSS_CONNECT_STORE or CROSS_CONNECT_STORE["active"] is None:
        # Return empty structure with 200 OK for RESTCONF standards & benchmark tools
        return jsonify({
            "example-quantum-switching-terminal-service:cross-connect-service": []
        }), 200

    return jsonify({
        "example-quantum-switching-terminal-service:cross-connect-service": [
            CROSS_CONNECT_STORE["active"]
        ]
    }), 200

@app.route('/restconf/data/example-quantum-switching-terminal-service:quantum-services/cross-connect-service', methods=['DELETE'])
def delete_cross_connect():
    sb_target = request.args.get("sb", "NETCONF")

    if "active" in CROSS_CONNECT_STORE and CROSS_CONNECT_STORE["active"] is not None:
        payload = CROSS_CONNECT_STORE.pop("active")
        success, details = dispatch_southbound_config("DELETE", payload, sb_target)
        if not success:
            return jsonify({"error": "Southbound device deletion failed", "details": details}), 502
        return jsonify({"status": "DELETED"}), 200

    # Idempotent DELETE: returning 200/204 when already cleared keeps benchmark loops running smoothly
    return jsonify({"status": "ALREADY_DELETED"}), 200

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8181)
