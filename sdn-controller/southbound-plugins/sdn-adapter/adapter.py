#!/usr/bin/env python3
"""
sdn-adapter — southbound protocol translator for the Quantum-SDN stack.

Speaks the BeagleBone's own dialects:
  - NETCONF: custom <set-netconf-switch> RPC over SSH on :8300
             (credentials sdn/quantum)
  - gNOI:    quantum.gnoi.switching.v1.QuantumGnoiSwitchingService
             SetCrossConnect(bool state) over gRPC on :50051

gNOI stubs are compiled from proto/quantum_gnoi_switching.proto at image
build time and imported directly — no grpcurl, no server reflection.
"""

from __future__ import annotations

import json
import logging
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

import grpc
from ncclient import manager as nc_manager

# Compiled gNOI stubs live alongside this file
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import quantum_gnoi_switching_pb2 as gnoi_pb2
import quantum_gnoi_switching_pb2_grpc as gnoi_grpc

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

PORT        = int(os.environ.get("ADAPTER_PORT", "8080"))
BIND        = os.environ.get("ADAPTER_BIND", "0.0.0.0")
NETCONF_TMO = int(os.environ.get("NETCONF_TIMEOUT", "10"))
GNOI_TMO    = int(os.environ.get("GNOI_TIMEOUT", "10"))

NETCONF_SWITCH_NS = "urn:quantum:sdn:netconf-switch"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
log = logging.getLogger("sdn-adapter")


# ---------------------------------------------------------------------------
# NETCONF — node's custom <set-netconf-switch> RPC
# ---------------------------------------------------------------------------

def netconf_set_switch(host: str, port: int, user: str, password: str,
                       state: bool) -> str:
    state_str = "true" if state else "false"
    rpc_body = (
        f'<set-netconf-switch xmlns="{NETCONF_SWITCH_NS}">'
        f'<state>{state_str}</state>'
        f'</set-netconf-switch>'
    )
    log.info("NETCONF set-netconf-switch host=%s port=%d state=%s",
             host, port, state_str)
    with nc_manager.connect(
        host=host,
        port=port,
        username=user,
        password=password,
        hostkey_verify=False,
        allow_agent=False,
        look_for_keys=False,
        device_params={"name": "default"},
        timeout=NETCONF_TMO,
    ) as m:
        reply = m.dispatch(rpc_body)
        return str(reply)


# ---------------------------------------------------------------------------
# gNOI — node's custom QuantumGnoiSwitchingService
# ---------------------------------------------------------------------------

def gnoi_set_crossconnect(host: str, port: int, state: bool) -> dict[str, Any]:
    target = f"{host}:{port}"
    log.info("gNOI SetCrossConnect target=%s state=%s", target, state)
    with grpc.insecure_channel(target) as channel:
        try:
            grpc.channel_ready_future(channel).result(timeout=GNOI_TMO)
        except grpc.FutureTimeoutError:
            raise RuntimeError(
                f"gRPC channel to {target} not ready within {GNOI_TMO}s"
            )

        stub = gnoi_grpc.QuantumGnoiSwitchingServiceStub(channel)
        req = gnoi_pb2.CrossConnectRequest(state=bool(state))
        try:
            resp = stub.SetCrossConnect(req, timeout=GNOI_TMO)
        except grpc.RpcError as e:
            raise RuntimeError(
                f"gRPC SetCrossConnect failed: {e.code().name}: {e.details()}"
            )
        return {
            "success": resp.success,
            "message": resp.message,
        }


def gnoi_get_crossconnect_status(host: str, port: int) -> dict[str, Any]:
    target = f"{host}:{port}"
    log.info("gNOI GetCrossConnectStatus target=%s", target)
    with grpc.insecure_channel(target) as channel:
        grpc.channel_ready_future(channel).result(timeout=GNOI_TMO)
        stub = gnoi_grpc.QuantumGnoiSwitchingServiceStub(channel)
        resp = stub.GetCrossConnectStatus(
            gnoi_pb2.StatusRequest(), timeout=GNOI_TMO
        )
        return {
            "is_connected": resp.is_connected,
            "switch_type":  resp.switch_type,
        }


# ---------------------------------------------------------------------------
# HTTP server
# ---------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    server_version = "sdn-adapter/2.0"

    def _json(self, code: int, body: Any) -> None:
        raw = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _read_json(self) -> dict[str, Any]:
        n = int(self.headers.get("Content-Length") or 0)
        if n == 0:
            return {}
        return json.loads(self.rfile.read(n).decode())

    def log_message(self, fmt, *args):
        log.info("%s - %s", self.address_string(), fmt % args)

    # -- GET --------------------------------------------------------------

    def do_GET(self):
        if self.path == "/healthz":
            return self._json(200, {"status": "ok"})
        if self.path == "/capabilities":
            return self._json(200, {
                "protocols": ["netconf", "gnoi"],
                "routes": [
                    "/netconf/switch",
                    "/gnoi/crossconnect",
                    "/gnoi/status",
                ],
            })
        return self._json(404, {"error": "not found"})

    # -- POST -------------------------------------------------------------

    def do_POST(self):
        try:
            body = self._read_json()
        except json.JSONDecodeError as e:
            return self._json(400, {"error": f"invalid json: {e}"})

        try:
            if self.path == "/netconf/switch":
                return self._handle_netconf_switch(body)
            if self.path == "/gnoi/crossconnect":
                return self._handle_gnoi_crossconnect(body)
            if self.path == "/gnoi/status":
                return self._handle_gnoi_status(body)
            return self._json(404, {"error": "not found"})
        except KeyError as e:
            return self._json(400, {"error": f"missing field: {e}"})
        except Exception as e:
            log.exception("request failed")
            return self._json(502, {"error": str(e)})

    # -- handlers ---------------------------------------------------------

    def _handle_netconf_switch(self, body):
        for f in ("host", "state"):
            if f not in body:
                return self._json(400, {"error": f"missing field: {f}"})
        out = netconf_set_switch(
            host=body["host"],
            port=int(body.get("port", 8300)),
            user=body.get("user", "sdn"),
            password=body.get("password", "quantum"),
            state=bool(body["state"]),
        )
        return self._json(200, {"ok": True, "reply": out})

    def _handle_gnoi_crossconnect(self, body):
        for f in ("host", "state"):
            if f not in body:
                return self._json(400, {"error": f"missing field: {f}"})
        out = gnoi_set_crossconnect(
            host=body["host"],
            port=int(body.get("port", 50051)),
            state=bool(body["state"]),
        )
        return self._json(200, {"ok": bool(out.get("success")), "reply": out})

    def _handle_gnoi_status(self, body):
        if "host" not in body:
            return self._json(400, {"error": "missing field: host"})
        out = gnoi_get_crossconnect_status(
            host=body["host"],
            port=int(body.get("port", 50051)),
        )
        return self._json(200, {"ok": True, "reply": out})


def main() -> None:
    server = ThreadingHTTPServer((BIND, PORT), Handler)
    log.info("sdn-adapter listening on %s:%d", BIND, PORT)
    server.serve_forever()


if __name__ == "__main__":
    main()
