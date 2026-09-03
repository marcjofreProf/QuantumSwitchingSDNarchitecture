import os
import subprocess
import json
from flask import Flask, request, jsonify

app = Flask(__name__)
# Targets the onos-config service running in the micro-onos Kubernetes namespace
GNMI_TARGET = os.getenv("GNMI_TARGET", "onos-config.micro-onos.svc.cluster.local:5150")

@app.route('/restconf/data/controller-quantum-switching:quantum-services/cross-connect-service', methods=['POST'])
def create_cross_connect():
    payload = request.json
    try:
        service = payload.get("cross-connect-service", [{}])[0]
        service_id = service.get("service-id")
        
        gnmi_path = f"/quantum-services/cross-connect-service[service-id={service_id}]"
        
        cmd = [
            "gnmic", "-a", GNMI_TARGET, "--skip-verify",
            "--target", service_id,
            "set", "--replace-path", gnmi_path,
            "--update-value", json.dumps(service)
        ]
        
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            return jsonify({"error": "gNMI Set failed", "details": result.stderr}), 500
            
        return jsonify({"status": "Success", "service-id": service_id}), 201
    except Exception as e:
        return jsonify({"error": str(e)}), 400

@app.route('/restconf/data/controller-quantum-switching:quantum-services/cross-connect-service/<service_id>', methods=['GET'])
def get_cross_connect(service_id):
    gnmi_path = f"/quantum-services/cross-connect-service[service-id={service_id}]"
    
    # Execute gNMI Get operation with TLS enabled (--skip-verify)
    cmd = [
        "gnmic", "-a", GNMI_TARGET, "--skip-verify",
        "--target", service_id,
        "get", "--path", gnmi_path
    ]
    
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        return jsonify({"error": "gNMI Get failed", "details": result.stderr}), 500
        
    return jsonify({"cross-connect-service": json.loads(result.stdout)}), 200

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8181)
