import os, subprocess, json
import requests
from flask import Flask, request, jsonify

app = Flask(__name__)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
GNMI_TARGET        = os.getenv("GNMI_TARGET", "onos-config.micro-onos.svc.cluster.local:5150")
DEFAULT_TARGET_DEVICE = os.getenv("GNMI_TARGET_DEVICE", "devicesim-1")
TLS_CERT           = os.getenv("TLS_CERT", "/etc/onos/certs/tls.crt")
TLS_KEY            = os.getenv("TLS_KEY",  "/etc/onos/certs/tls.key")

# Southbound adapter (NETCONF / gNOI)
ADAPTER_URL        = os.getenv("ADAPTER_URL", "http://sdn-adapter.micro-onos.svc:8080")
ADAPTER_TIMEOUT    = float(os.getenv("ADAPTER_TIMEOUT", "10"))

# Ports/credentials for the non-gNMI southbound legs
NETCONF_PORT       = int(os.getenv("NETCONF_PORT", "8300"))
GNOI_PORT          = int(os.getenv("GNOI_PORT",    "50051"))
NETCONF_USER       = os.getenv("NETCONF_USER", "admin")
NETCONF_PASS       = os.getenv("NETCONF_PASS", "admin")

CROSS_CONNECT_STORE = {}


# ---------------------------------------------------------------------------
# gNMI helper (unchanged)
# ---------------------------------------------------------------------------
def get_gnmic_base_cmd():
    cmd = ["gnmic", "-a", GNMI_TARGET, "--skip-verify"]
    if os.path.exists(TLS_CERT) and os.path.exists(TLS_KEY):
        cmd.extend(["--tls-cert", TLS_CERT, "--tls-key", TLS_KEY])
    return cmd


# ---------------------------------------------------------------------------
# Payload extraction (unchanged)
# ---------------------------------------------------------------------------
def _extract_payload(payload):
    if isinstance(payload, dict) and "cross-connect-service" in payload:
        items = payload["cross-connect-service"]
        return items[0] if isinstance(items, list) and items else {}
    return payload if isinstance(payload, dict) else {}


# ---------------------------------------------------------------------------
# Adapter helpers (new)
# ---------------------------------------------------------------------------
def _adapter_post(path, body):
    url = f"{ADAPTER_URL}{path}"
    try:
        r = requests.post(url, json=body, timeout=ADAPTER_TIMEOUT)
    except requests.RequestException as e:
        return False, f"adapter unreachable at {url}: {e}"
    if not r.ok:
        return False, f"adapter {path} returned HTTP {r.status_code}: {r.text[:512]}"
    try:
        return True, json.dumps(r.json())
    except ValueError:
        return True, r.text


def _dispatch_netconf(action, data):
    host = data.get("target-node-ip") or data.get("target-node")
    if not host:
        return False, "payload missing target-node-ip / target-node"

    state = "enabled" if action == "SET" else "disabled"
    config_xml = (
        '<config xmlns="urn:ietf:params:xml:ns:netconf:base:1.0">'
        '<switching xmlns="urn:custom:params:xml:ns:yang:controller-quantum-switching">'
        f'<state>{state}</state>'
        '</switching></config>'
    )
    return _adapter_post("/netconf/edit", {
        "host":     host,
        "port":     NETCONF_PORT,
        "user":     NETCONF_USER,
        "password": NETCONF_PASS,
        "config":   config_xml,
        "target":   "running",
    })


def _dispatch_gnoi(action, data):
    host = data.get("target-node-ip") or data.get("target-node")
    if not host:
        return False, "payload missing target-node-ip / target-node"

    # gNOI is an operational API — it has no generic "set config" method.
    # System.Time is a safe, read-only RPC that still exercises the gNOI
    # service over the wire. Replace the service/method below with the
    # vendor RPC that actually toggles switching state if your device has
    # one.
    return _adapter_post("/gnoi/invoke", {
        "host":    host,
        "port":    GNOI_PORT,
        "service": "gnoi.system.System",
        "method":  "Time",
        "payload": {},
    })


# ---------------------------------------------------------------------------
# gNMI dispatcher (unchanged)
# ---------------------------------------------------------------------------
def _dispatch_gnmi(action, data):
    target_device = data.get("target-node") or data.get("target-node-ip") or DEFAULT_TARGET_DEVICE
    service_id    = data.get("service-id", "qservice")
    ingress_port  = data.get("ingress-port", 1)
    if_name       = f"eth{ingress_port}"

    if action == "DELETE":
        cmd = get_gnmic_base_cmd() + [
            "--target", target_device,
            "set",
            "--delete", f"/interfaces/interface[name={if_name}]/config/description",
        ]
    else:
        payload_json = json.dumps({
            "name": if_name,
            "config": {"name": if_name, "description": service_id, "enabled": True},
        })
        cmd = get_gnmic_base_cmd() + [
            "--target", target_device,
            "set",
            "--update",
            f"/interfaces/interface[name={if_name}]:::json_ietf:::{payload_json}",
        ]

    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
        if result.returncode != 0:
            return False, result.stderr
        return True, result.stdout
    except subprocess.TimeoutExpired:
        return False, "gnmic request to onos-config timed out after 5s"


# ---------------------------------------------------------------------------
# Router — this is the whole point of the patch
# ---------------------------------------------------------------------------
def dispatch_southbound_config(action, payload, sb_target):
    data = _extract_payload(payload)
    sb   = (sb_target or "gNMI").upper()

    if sb == "NETCONF":
        return _dispatch_netconf(action, data)
    if sb == "GNOI":
        return _dispatch_gnoi(action, data)
    # Fall through: anything else (including "gNMI" and unknown values)
    # uses the existing onos-config gNMI path.
    return _dispatch_gnmi(action, data)


# ---------------------------------------------------------------------------
# RESTCONF routes
# ---------------------------------------------------------------------------
@app.route(
    "/restconf/data/example-quantum-switching-terminal-service:quantum-services/cross-connect-service",
    methods=["POST", "PUT"],
)
def create_cross_connect():
    payload   = request.json or {}
    sb_target = request.headers.get("X-Southbound-Target", "gNMI")

    success, details = dispatch_southbound_config("SET", payload, sb_target)
    if not success:
        return jsonify({"error": "Southbound device push failed",
                        "sb": sb_target, "details": details}), 502

    CROSS_CONNECT_STORE["active"] = payload
    return jsonify({"status": "SUCCESS", "service": payload, "sb": sb_target}), 201


@app.route(
    "/restconf/data/example-quantum-switching-terminal-service:quantum-services/cross-connect-service",
    methods=["GET"],
)
def get_cross_connect():
    if "active" not in CROSS_CONNECT_STORE or CROSS_CONNECT_STORE["active"] is None:
        return jsonify({
            "example-quantum-switching-terminal-service:cross-connect-service": []
        }), 200
    return jsonify({
        "example-quantum-switching-terminal-service:cross-connect-service": [
            CROSS_CONNECT_STORE["active"]
        ]
    }), 200


@app.route(
    "/restconf/data/example-quantum-switching-terminal-service:quantum-services/cross-connect-service",
    methods=["DELETE"],
)
def delete_cross_connect():
    sb_target = request.args.get("sb", "gNMI")

    if "active" in CROSS_CONNECT_STORE and CROSS_CONNECT_STORE["active"] is not None:
        payload = CROSS_CONNECT_STORE.pop("active")
        success, details = dispatch_southbound_config("DELETE", payload, sb_target)
        if not success:
            return jsonify({"error": "Southbound device deletion failed",
                            "sb": sb_target, "details": details}), 502
        return jsonify({"status": "DELETED", "sb": sb_target}), 200

    return jsonify({"status": "ALREADY_DELETED"}), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8181)
