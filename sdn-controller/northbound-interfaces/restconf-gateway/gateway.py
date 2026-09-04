import os
import subprocess
import json
from flask import Flask, request, jsonify

app = Flask(__name__)

GNMI_TARGET = os.getenv("GNMI_TARGET", "onos-config.micro-onos.svc.cluster.local:5150")
GNMI_TARGET_DEVICE = os.getenv("GNMI_TARGET_DEVICE", "devicesim-1")
TLS_CERT = os.getenv("TLS_CERT", "/etc/onos/certs/tls.crt")
TLS_KEY = os.getenv("TLS_KEY", "/etc/onos/certs/tls.key")

def get_gnmic_cmd():
    cmd = ["gnmic", "-a", GNMI_TARGET, "--skip-verify"]
    if os.path.exists(TLS_CERT) and os.path.exists(TLS_KEY):
        cmd.extend(["--tls-cert", TLS_CERT, "--tls-key", TLS_KEY])
    return cmd

@app.route('/restconf/data/controller-quantum-switching:quantum-services/cross-connect-service', methods=['POST'])
def create_cross_connect():
    payload = request.json
    try:
        service = payload.get("cross-connect-service", [{}])[0]
        service_id = service.get("service-id")
        
        gnmi_path = f"/quantum-services/cross-connect-service[service-id={service_id}]"
        target_device = request.args.get("target", GNMI_TARGET_DEVICE)
        
        cmd = get_gnmic_cmd() + [
            "--target", target_device,
            "set",
            "--update", f"{gnmi_path}:::json:::{json.dumps(service)}"
        ]
        
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            return jsonify({"error": "gNMI Set failed", "details": result.stderr}), 500
            
        return jsonify({"status": "Success", "service-id": service_id}), 201
    except Exception as e:
        return jsonify({"error": str(e)}), 400

@app.route('/restconf/data/controller-quantum-switching:quantum-services/cross-connect-service=<service_id>', methods=['GET'])
@app.route('/restconf/data/controller-quantum-switching:quantum-services/cross-connect-service/<service_id>', methods=['GET'])
def get_cross_connect(service_id):
    gnmi_path = f"/quantum-services/cross-connect-service[service-id={service_id}]"
    target_device = request.args.get("target", GNMI_TARGET_DEVICE)
    
    cmd = get_gnmic_cmd() + [
        "--target", target_device,
        "get",
        "--path", gnmi_path
    ]
    
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        return jsonify({"error": "gNMI Get failed", "details": result.stderr}), 500
        
    return jsonify({"cross-connect-service": json.loads(result.stdout)}), 200

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8181)
