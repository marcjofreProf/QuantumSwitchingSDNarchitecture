import os, sys, json, threading
import grpc
import requests
from flask import Flask, request, jsonify

# gNMI stubs are compiled into /app at image build time.
sys.path.insert(0, "/app")
import gnmi_pb2
import gnmi_pb2_grpc

app = Flask(__name__)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
GNMI_TARGET        = os.getenv("GNMI_TARGET", "onos-config.micro-onos.svc.cluster.local:5150")
DEFAULT_TARGET_DEVICE = os.getenv("GNMI_TARGET_DEVICE", "devicesim-1")
TLS_CA             = os.getenv("TLS_CA",   "/etc/onos/certs/tls.cacrt")
TLS_CERT           = os.getenv("TLS_CERT", "/etc/onos/certs/tls.crt")
TLS_KEY            = os.getenv("TLS_KEY",  "/etc/onos/certs/tls.key")
GNMI_TIMEOUT       = float(os.getenv("GNMI_TIMEOUT", "5"))
KEEPALIVE_INTERVAL = int(os.getenv("KEEPALIVE_INTERVAL", "30"))

ADAPTER_URL        = os.getenv("ADAPTER_URL", "http://sdn-adapter.micro-onos.svc:8080")
ADAPTER_TIMEOUT    = float(os.getenv("ADAPTER_TIMEOUT", "10"))

NETCONF_PORT       = int(os.getenv("NETCONF_PORT", "8300"))
GNOI_PORT          = int(os.getenv("GNOI_PORT",    "50051"))
NETCONF_USER       = os.getenv("NETCONF_USER", "admin")
NETCONF_PASS       = os.getenv("NETCONF_PASS", "admin")

CROSS_CONNECT_STORE = {}

# onos-config addresses devices by their topo id, not by IP. Payloads
# arriving from the benchmark or a RESTCONF caller may carry either form.
# This table lets the gateway normalise both to the id onos-config knows.
#
# The node id and IP are configurable via environment variables so a
# single image can be deployed against different physical nodes. The
# defaults below match the MANO / 6G-OpenLab convention used by
# bootstrap-node.sh and bootstrap-quantum-switching-sdn.sh.
_QUANTUM_NODE_ID = os.getenv("QUANTUM_NODE_ID", "quantum-node-1")
_QUANTUM_NODE_IP = os.getenv("QUANTUM_NODE_IP", "172.21.128.254")

# onos-config addresses devices by their topo id. This table maps anything
# a caller might send (id or IP) to the id onos-config expects.
KNOWN_DEVICES = {
    _QUANTUM_NODE_ID:                _QUANTUM_NODE_ID,
    _QUANTUM_NODE_IP:                _QUANTUM_NODE_ID,
    f"{_QUANTUM_NODE_IP}:50051":     _QUANTUM_NODE_ID,
}

# The southbound adapter, on the other hand, needs an IP to dial. This
# table maps anything a caller might send (id or IP) to the IP the
# adapter should connect to. Without this, a payload that carries the
# topo entity name in `target-node-ip` results in the adapter trying to
# DNS-resolve "quantum-node-1", which fails inside the cluster.
ADAPTER_TARGETS = {
    _QUANTUM_NODE_ID: _QUANTUM_NODE_IP,
    _QUANTUM_NODE_IP: _QUANTUM_NODE_IP,
}

app.logger.info("KNOWN_DEVICES: %s (node=%s ip=%s)",
                list(KNOWN_DEVICES.keys()), _QUANTUM_NODE_ID, _QUANTUM_NODE_IP)


def _resolve_target(data):
    """Return the device id onos-config expects, given a payload that
    may carry `target-node` (id), `target-node-ip` (IP), or both."""
    tid = (data.get("target-node")    or "").strip()
    tip = (data.get("target-node-ip") or "").strip()

    for candidate in (tid, tip):
        if candidate in KNOWN_DEVICES:
            return KNOWN_DEVICES[candidate]

    # Unknown device — pass it through and let onos-config report the
    # miss with a specific error, instead of silently defaulting.
    return tid or tip or DEFAULT_TARGET_DEVICE


# ---------------------------------------------------------------------------
# Health probe — this is the endpoint the K8s HTTP probes hit
# ---------------------------------------------------------------------------
@app.route("/healthz", methods=["GET"])
def healthz():
    return jsonify({"status": "ok"}), 200


# ---------------------------------------------------------------------------
# gNMI — persistent channel with HTTP/2 keepalives
#
# Replaces the previous per-request `gnmic` subprocess. The channel is
# created once and reused for the lifetime of the process. Keepalive
# options ensure the TCP flow survives stateful firewalls between the
# gateway and onos-config (relevant when the cluster spans subnets).
#
# grpc.Channel is thread-safe, so no lock is needed for RPC calls. The
# lock is only held when (re)creating the channel after a UNAVAILABLE.
# ---------------------------------------------------------------------------

_GNMI_CHANNEL_OPTIONS = [
    ("grpc.keepalive_time_ms",     KEEPALIVE_INTERVAL * 1000),
    ("grpc.keepalive_timeout_ms",  10000),
    ("grpc.keepalive_permit_without_calls", 1),
    ("grpc.http2.min_ping_interval_without_data_ms", 10000),
    ("grpc.http2.max_pings_without_data", 0),
]

_gnmi_channel = None
_gnmi_stub    = None
_gnmi_lock    = threading.Lock()


def _load_tls():
    """Return (root_certs, private_key, cert_chain) as bytes."""
    root = open(TLS_CA,   "rb").read() if os.path.exists(TLS_CA)   else None
    key  = open(TLS_KEY,  "rb").read() if os.path.exists(TLS_KEY)  else None
    crt  = open(TLS_CERT, "rb").read() if os.path.exists(TLS_CERT) else None
    return root, key, crt


def _get_gnmi_stub():
    global _gnmi_channel, _gnmi_stub
    if _gnmi_stub is not None:
        return _gnmi_stub
    with _gnmi_lock:
        if _gnmi_stub is not None:
            return _gnmi_stub
        root, key, crt = _load_tls()
        if root and key and crt:
            creds = grpc.ssl_channel_credentials(
                root_certificates=root,
                private_key=key,
                certificate_chain=crt,
            )
            _gnmi_channel = grpc.secure_channel(
                GNMI_TARGET, creds, options=_GNMI_CHANNEL_OPTIONS)
            app.logger.info("gNMI channel: mTLS to %s (keepalive %ds)",
                            GNMI_TARGET, KEEPALIVE_INTERVAL)
        else:
            _gnmi_channel = grpc.insecure_channel(
                GNMI_TARGET, options=_GNMI_CHANNEL_OPTIONS)
            app.logger.warning(
                "gNMI channel: INSECURE to %s (TLS material missing)",
                GNMI_TARGET)
        _gnmi_stub = gnmi_pb2_grpc.gNMIStub(_gnmi_channel)
        return _gnmi_stub


def _reset_gnmi_channel():
    global _gnmi_channel, _gnmi_stub
    with _gnmi_lock:
        if _gnmi_channel is not None:
            try: _gnmi_channel.close()
            except Exception: pass
        _gnmi_channel = None
        _gnmi_stub = None


def _gnmi_set(target_id, path_elems, string_val=None, delete=False):
    path   = gnmi_pb2.Path(elem=[gnmi_pb2.PathElem(name=n) for n in path_elems])
    prefix = gnmi_pb2.Path(target=target_id)
    if delete:
        req = gnmi_pb2.SetRequest(prefix=prefix, delete=[path])
    else:
        req = gnmi_pb2.SetRequest(
            prefix=prefix,
            update=[gnmi_pb2.Update(
                path=path,
                val=gnmi_pb2.TypedValue(string_val=string_val),
            )],
        )
    return _get_gnmi_stub().Set(req, timeout=GNMI_TIMEOUT)


def _gnmi_set_with_retry(target_id, path_elems, string_val=None, delete=False):
    try:
        return _gnmi_set(target_id, path_elems,
                         string_val=string_val, delete=delete)
    except grpc.RpcError as e:
        if e.code() not in (grpc.StatusCode.UNAVAILABLE,
                            grpc.StatusCode.UNKNOWN):
            raise
        app.logger.warning(
            "gNMI Set failed (%s); resetting channel and retrying once",
            e.code().name)
        _reset_gnmi_channel()
        return _gnmi_set(target_id, path_elems,
                         string_val=string_val, delete=delete)

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


def _resolve_adapter_host(data):
    """Return the IP the adapter should dial, given either the topo id
    or the IP in the payload."""
    raw = (data.get("target-node-ip") or data.get("target-node") or "").strip()
    return ADAPTER_TARGETS.get(raw, raw)


def _dispatch_netconf(action, data):
    host = _resolve_adapter_host(data)
    if not host:
        return False, "payload missing target-node-ip / target-node"

    # SET (POST/PUT) → enable the switch; DELETE → disable it.
    state = (action == "SET")

    return _adapter_post("/netconf/switch", {
        "host":     host,
        "port":     NETCONF_PORT,
        "user":     NETCONF_USER,
        "password": NETCONF_PASS,
        "state":    state,
    })


def _dispatch_gnoi(action, data):
    host = _resolve_adapter_host(data)
    if not host:
        return False, "payload missing target-node-ip / target-node"

    state = (action == "SET")

    return _adapter_post("/gnoi/crossconnect", {
        "host":  host,
        "port":  GNOI_PORT,
        "state": state,
    })


# ---------------------------------------------------------------------------
# gNMI dispatcher — native gRPC, no subprocess
# ---------------------------------------------------------------------------
def _dispatch_gnmi(action, data):
    target_id = _resolve_target(data)
    try:
        if action == "DELETE":
            _gnmi_set_with_retry(target_id, ["switching", "state"],
                                 delete=True)
        else:
            _gnmi_set_with_retry(target_id, ["switching", "state"],
                                 string_val="enabled")
        return True, f"gNMI Set OK target={target_id} action={action}"
    except grpc.RpcError as e:
        return False, f"gNMI Set failed ({e.code().name}): {e.details()}"
    except Exception as e:
        return False, f"gNMI Set failed: {e}"

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
