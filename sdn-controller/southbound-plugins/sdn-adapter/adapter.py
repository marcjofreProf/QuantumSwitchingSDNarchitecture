#!/usr/bin/env python3
"""
sdn-adapter — southbound protocol translator for the Quantum-SDN stack.

onos-config speaks only gNMI southbound. This service fills the gap for
protocols it does not natively support: NETCONF (RFC 6241 over SSH) and
gNOI (gRPC). It is called by the RESTCONF gateway whenever the inbound
request carries an `X-Southbound-Target` header that is not `gNMI`.

Routes
------
GET  /healthz              Liveness/readiness probe.
GET  /capabilities         Enumerate supported protocols and routes.
POST /netconf/edit         NETCONF <edit-config> with a caller-supplied payload.
POST /netconf/get          NETCONF <get-config> with an optional subtree filter.
POST /gnoi/reboot          gNOI System.Reboot.
POST /gnoi/time            gNOI System.Time (a no-op probe of the gNOI service).
POST /gnoi/invoke          Generic gNOI method invocation via grpcurl.

All POST routes accept and return JSON. Errors are returned as
{"error": "..."} with an appropriate HTTP status code.
"""

from __future__ import annotations

import json
import logging
import os
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

from ncclient import manager as nc_manager

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

PORT           = int(os.environ.get("ADAPTER_PORT", "8080"))
BIND           = os.environ.get("ADAPTER_BIND", "0.0.0.0")
NETCONF_TMO    = int(os.environ.get("NETCONF_TIMEOUT", "10"))
GNOI_TMO       = int(os.environ.get("GNOI_TIMEOUT", "15"))

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
log = logging.getLogger("sdn-adapter")


# ---------------------------------------------------------------------------
# NETCONF helpers
# ---------------------------------------------------------------------------

def netconf_edit(host: str, port: int, user: str, password: str,
                 config_xml: str, target: str = "running") -> str:
    log.info("NETCONF edit-config host=%s port=%d target=%s", host, port, target)
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
        reply = m.edit_config(target=target, config=config_xml)
        return str(reply)


def netconf_get(host: str, port: int, user: str, password: str,
                filter_xml: str | None = None, source: str = "running") -> str:
    log.info("NETCONF get-config host=%s port=%d source=%s", host, port, source)
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
        if filter_xml:
            reply = m.get_config(source=source, filter=("subtree", filter_xml))
        else:
            reply = m.get_config(source=source)
        return str(reply)


# ---------------------------------------------------------------------------
# gNOI helpers (via grpcurl + server reflection)
# ---------------------------------------------------------------------------

def grpcurl(host: str, port: int, method: str,
            payload: dict[str, Any],
            timeout: int = GNOI_TMO) -> dict[str, Any]:
    """Invoke an arbitrary gRPC/gNOI method via grpcurl + server reflection."""
    cmd = [
        "grpcurl",
        "-plaintext",
        "-max-time", str(timeout),
        "-d", json.dumps(payload),
        f"{host}:{port}",
        method,
    ]
    log.info("grpcurl method=%s target=%s:%d", method, host, port)
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True,
                              timeout=timeout + 5)
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"grpcurl timed out after {timeout}s")

    if proc.returncode != 0:
        raise RuntimeError(
            f"grpcurl failed (rc={proc.returncode}): {proc.stderr.strip()}"
        )
    out = proc.stdout.strip()
    if not out:
        return {}
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return {"raw": out}


def gnoi_reboot(host: str, port: int, method: str = "COLD",
                delay: int = 0, message: str = "", force: bool = True):
    return grpcurl(
        host, port,
        "gnoi.system.System/Reboot",
        {"method": method, "delay": delay, "message": message, "force": force},
    )


def gnoi_time(host: str, port: int):
    return grpcurl(host, port, "gnoi.system.System/Time", {})


def gnoi_invoke(host: str, port: int, service: str, method: str,
                payload: dict[str, Any]):
    return grpcurl(host, port, f"{service}/{method}", payload)


# ---------------------------------------------------------------------------
# HTTP server
# ---------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    server_version = "sdn-adapter/1.0"

    # --- helpers ---------------------------------------------------------

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

    def log_message(self, fmt, *args):  # quieter access log
        log.info("%s - %s", self.address_string(), fmt % args)

    # --- GET -------------------------------------------------------------

    def do_GET(self):
        if self.path == "/healthz":
            return self._json(200, {"status": "ok"})
        if self.path == "/capabilities":
            return self._json(200, {
                "protocols": ["netconf", "gnoi"],
                "netconf_routes": ["/netconf/edit", "/netconf/get"],
                "gnoi_routes": ["/gnoi/reboot", "/gnoi/time", "/gnoi/invoke"],
            })
        return self._json(404, {"error": "not found"})

    # --- POST ------------------------------------------------------------

    def do_POST(self):
        try:
            body = self._read_json()
        except json.JSONDecodeError as e:
            return self._json(400, {"error": f"invalid json: {e}"})

        try:
            if self.path == "/netconf/edit":
                return self._handle_netconf_edit(body)
            if self.path == "/netconf/get":
                return self._handle_netconf_get(body)
            if self.path == "/gnoi/reboot":
                return self._handle_gnoi_reboot(body)
            if self.path == "/gnoi/time":
                return self._handle_gnoi_time(body)
            if self.path == "/gnoi/invoke":
                return self._handle_gnoi_invoke(body)
            return self._json(404, {"error": "not found"})
        except KeyError as e:
            return self._json(400, {"error": f"missing field: {e}"})
        except Exception as e:
            log.exception("request failed")
            return self._json(500, {"error": str(e)})

    # --- handlers --------------------------------------------------------

    def _handle_netconf_edit(self, body):
        for f in ("host", "config"):
            if f not in body:
                return self._json(400, {"error": f"missing field: {f}"})
        out = netconf_edit(
            host=body["host"],
            port=int(body.get("port", 830)),
            user=body.get("user", "admin"),
            password=body.get("password", "admin"),
            config_xml=body["config"],
            target=body.get("target", "running"),
        )
        return self._json(200, {"ok": True, "reply": out})

    def _handle_netconf_get(self, body):
        if "host" not in body:
            return self._json(400, {"error": "missing field: host"})
        out = netconf_get(
            host=body["host"],
            port=int(body.get("port", 830)),
            user=body.get("user", "admin"),
            password=body.get("password", "admin"),
            filter_xml=body.get("filter"),
            source=body.get("source", "running"),
        )
        return self._json(200, {"ok": True, "reply": out})

    def _handle_gnoi_reboot(self, body):
        if "host" not in body:
            return self._json(400, {"error": "missing field: host"})
        out = gnoi_reboot(
            host=body["host"],
            port=int(body.get("port", 50051)),
            method=body.get("method", "COLD"),
            delay=int(body.get("delay", 0)),
            message=body.get("message", ""),
            force=bool(body.get("force", True)),
        )
        return self._json(200, {"ok": True, "reply": out})

    def _handle_gnoi_time(self, body):
        if "host" not in body:
            return self._json(400, {"error": "missing field: host"})
        out = gnoi_time(
            host=body["host"],
            port=int(body.get("port", 50051)),
        )
        return self._json(200, {"ok": True, "reply": out})

    def _handle_gnoi_invoke(self, body):
        for f in ("host", "service", "method"):
            if f not in body:
                return self._json(400, {"error": f"missing field: {f}"})
        out = gnoi_invoke(
            host=body["host"],
            port=int(body.get("port", 50051)),
            service=body["service"],
            method=body["method"],
            payload=body.get("payload", {}),
        )
        return self._json(200, {"ok": True, "reply": out})


def main() -> None:
    server = ThreadingHTTPServer((BIND, PORT), Handler)
    log.info("sdn-adapter listening on %s:%d", BIND, PORT)
    server.serve_forever()


if __name__ == "__main__":
    main()
