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
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from ncclient.xml_ import to_ele

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

# ---------------------------------------------------------------------------
# Connection pooling + keepalive configuration
#
# In routed deployments (controller and node on different subnets, with
# stateful firewalls or NAT in between) a pooled connection can be silently
# dropped by the middlebox while the client's kernel still shows it as
# ESTABLISHED. The next RPC then fails on a socket the OS thinks is alive.
#
# Both SSH and HTTP/2 have native keepalive mechanisms that solve this:
# they send small periodic probes that keep the flow alive in any stateful
# device and detect a dead peer within seconds. We enable them on every
# pooled connection.
# ---------------------------------------------------------------------------
POOL_ENABLED     = os.environ.get("POOL_ENABLED", "true").lower() == "true"

# Seconds between keepalive probes. 30 s is short enough to survive the
# most aggressive enterprise firewall idle-timeout (typically 5-15 min)
# and long enough not to be chatter.
KEEPALIVE_INTERVAL = int(os.environ.get("KEEPALIVE_INTERVAL", "30"))

# How long a pooled connection is allowed to sit idle before it is
# reaped on the next acquire. 60 s is well below any plausible firewall
# timeout while still covering the burst cadence of the benchmark.
CONN_IDLE_TTL    = int(os.environ.get("CONN_IDLE_TTL", "60"))

# Upper bound on pooled entries per protocol. Entries beyond this are
# evicted oldest-first.
CONN_MAX_POOL    = int(os.environ.get("CONN_MAX_POOL", "16"))

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
log = logging.getLogger("sdn-adapter")


# ---------------------------------------------------------------------------
# NETCONF — pooled SSH sessions with SSH keepalives
# ---------------------------------------------------------------------------

# key = (host, port, user, password) → {"mgr": Manager, "lock": RLock, "last": monotonic}
_netconf_pool: dict[tuple, dict] = {}
_netconf_pool_lock = threading.Lock()


def _netconf_key(host, port, user, password):
    return (host, port, user, password)


def _netconf_open(key):
    host, port, user, password = key
    log.info("NETCONF pool: opening session to %s:%d as %s", host, port, user)
    mgr = nc_manager.connect(
        host=host, port=port,
        username=user, password=password,
        hostkey_verify=False,
        allow_agent=False,
        look_for_keys=False,
        device_params={"name": "default"},
        timeout=NETCONF_TMO,
    )
    # Enable SSH-level keepalives on the underlying paramiko transport.
    # Sends SSH_MSG_IGNORE (or an SSH global request) every N seconds,
    # which:
    #   (a) keeps NAT and stateful-firewall flow entries alive across
    #       routed networks where idle TCP sessions are silently dropped;
    #   (b) makes the transport detect a genuinely dead peer within
    #       ~3 × KEEPALIVE_INTERVAL seconds instead of the kernel default
    #       of ~2 hours.
    # ncclient wraps paramiko, and the transport is reachable through a
    # private attribute whose name varies between ncclient versions, so
    # probe both spellings.
    try:
        transport = getattr(mgr, "_transport", None)
        if transport is None and hasattr(mgr, "_session"):
            transport = getattr(mgr._session, "_transport", None)
        if transport is not None:
            transport.set_keepalive(KEEPALIVE_INTERVAL)
            log.info("NETCONF pool: SSH keepalive enabled (%ds) for %s:%d",
                     KEEPALIVE_INTERVAL, host, port)
        else:
            log.warning("NETCONF pool: could not locate transport; "
                        "keepalive not enabled for %s:%d", host, port)
    except Exception as e:
        log.warning("NETCONF pool: keepalive enable failed for %s:%d: %s",
                    host, port, e)
    return mgr


def _netconf_close(mgr):
    try:
        mgr.close_session()
    except Exception:
        pass
    try:
        if hasattr(mgr, "close"):
            mgr.close()
    except Exception:
        pass


def _netconf_reap_locked(now):
    """Must be called with _netconf_pool_lock held."""
    stale = [k for k, e in _netconf_pool.items()
             if now - e["last"] > CONN_IDLE_TTL]
    for k in stale:
        e = _netconf_pool.pop(k)
        log.info("NETCONF pool: reaping idle session %s:%d", k[0], k[1])
        _netconf_close(e["mgr"])
    while len(_netconf_pool) > CONN_MAX_POOL:
        k = next(iter(_netconf_pool))
        e = _netconf_pool.pop(k)
        log.info("NETCONF pool: evicting session %s:%d (pool full)", k[0], k[1])
        _netconf_close(e["mgr"])


def _netconf_acquire(key):
    """Return (Manager, RLock). Opens a fresh session if pooling is off,
    if the key is unknown, or if a pooled session has died."""
    if not POOL_ENABLED:
        return _netconf_open(key), threading.RLock()
    with _netconf_pool_lock:
        _netconf_reap_locked(time.monotonic())
        entry = _netconf_pool.get(key)
        if entry is not None:
            # With SSH keepalives running, `.connected` is a genuine
            # liveness signal: it flips to False within ~3×KA when the
            # peer goes away. Checking it here means we never fire a
            # doomed RPC on a socket the kernel thinks is alive.
            if getattr(entry["mgr"], "connected", True):
                entry["last"] = time.monotonic()
                return entry["mgr"], entry["lock"]
            log.warning("NETCONF pool: dead session detected for %s:%d; "
                        "reconnecting", key[0], key[1])
            _netconf_pool.pop(key)
            _netconf_close(entry["mgr"])
        mgr = _netconf_open(key)
        entry = {"mgr": mgr, "lock": threading.RLock(), "last": time.monotonic()}
        _netconf_pool[key] = entry
        log.info("NETCONF pool: size=%d", len(_netconf_pool))
        return mgr, entry["lock"]


def _netconf_drop(key):
    with _netconf_pool_lock:
        entry = _netconf_pool.pop(key, None)
    if entry:
        log.warning("NETCONF pool: dropping session %s:%d", key[0], key[1])
        _netconf_close(entry["mgr"])


def netconf_set_switch(host: str, port: int, user: str, password: str, state: bool) -> str:
    state_str = "true" if state else "false"
    rpc_xml = (
        '<rpc message-id="1" xmlns="urn:ietf:params:xml:ns:netconf:base:1.0">'
        f'<set-netconf-switch xmlns="{NETCONF_SWITCH_NS}">'
        f'<state>{state_str}</state>'
        f'</set-netconf-switch>'
        '</rpc>'
    )
    rpc_ele = to_ele(rpc_xml)
    key = _netconf_key(host, port, user, password)

    log.info("NETCONF set-netconf-switch host=%s port=%d state=%s",
             host, port, state_str)

    def _do():
        mgr, lock = _netconf_acquire(key)
        # ncclient Managers are not documented thread-safe; serialize.
        with lock:
            return str(mgr.dispatch(rpc_ele))

    try:
        return _do()
    except Exception as e:
        # A pooled session can still die mid-RPC even with keepalives
        # (firewall drops between probes, node restarts, etc.). Drop
        # and retry once against a fresh connection so a dead socket
        # never surfaces to the caller.
        log.warning("NETCONF RPC failed on pooled session (%s); "
                    "reconnecting once", e)
        _netconf_drop(key)
        return _do()


# ---------------------------------------------------------------------------
# gNOI — pooled gRPC channels with HTTP/2 keepalives
# ---------------------------------------------------------------------------

# Standard gRPC channel options for surviving routed networks. gRPC does
# NOT enable HTTP/2 keepalives by default; without these, an idle channel
# goes completely silent and a stateful firewall will drop its flow after
# the configured timeout. The next RPC then fails with UNAVAILABLE on a
# socket the kernel still shows as ESTABLISHED.
_GNOI_CHANNEL_OPTIONS = [
    # Send a PING every KEEPALIVE_INTERVAL seconds.
    ("grpc.keepalive_time_ms", KEEPALIVE_INTERVAL * 1000),
    # Consider the connection dead if no ACK within 10 s.
    ("grpc.keepalive_timeout_ms", 10000),
    # Send PINGs even when no RPC is in flight. Without this, gRPC stays
    # silent between calls and the firewall times the flow out anyway.
    ("grpc.keepalive_permit_without_calls", 1),
    # Permit server pings as well (symmetrical keepalive).
    ("grpc.http2.min_ping_interval_without_data_ms", 10000),
    # Do not cap how many pings we send without data.
    ("grpc.http2.max_pings_without_data", 0),
]

# target = "host:port" → {"channel": Channel, "stub": Stub, "last": monotonic}
_gnoi_pool: dict[str, dict] = {}
_gnoi_pool_lock = threading.Lock()


def _gnoi_open(target):
    log.info("gNOI pool: opening channel to %s", target)
    channel = grpc.insecure_channel(target, options=_GNOI_CHANNEL_OPTIONS)
    try:
        grpc.channel_ready_future(channel).result(timeout=GNOI_TMO)
    except grpc.FutureTimeoutError:
        channel.close()
        raise RuntimeError(f"gRPC channel to {target} not ready within {GNOI_TMO}s")
    stub = gnoi_grpc.QuantumGnoiSwitchingServiceStub(channel)
    log.info("gNOI pool: HTTP/2 keepalive enabled (%ds) for %s",
             KEEPALIVE_INTERVAL, target)
    return channel, stub


def _gnoi_reap_locked(now):
    stale = [k for k, e in _gnoi_pool.items()
             if now - e["last"] > CONN_IDLE_TTL]
    for k in stale:
        e = _gnoi_pool.pop(k)
        log.info("gNOI pool: reaping idle channel %s", k)
        try: e["channel"].close()
        except Exception: pass
    while len(_gnoi_pool) > CONN_MAX_POOL:
        k = next(iter(_gnoi_pool))
        e = _gnoi_pool.pop(k)
        log.info("gNOI pool: evicting channel %s (pool full)", k)
        try: e["channel"].close()
        except Exception: pass


def _gnoi_acquire(target):
    if not POOL_ENABLED:
        _, stub = _gnoi_open(target)
        return stub
    with _gnoi_pool_lock:
        _gnoi_reap_locked(time.monotonic())
        entry = _gnoi_pool.get(target)
        if entry is not None:
            entry["last"] = time.monotonic()
            return entry["stub"]
        channel, stub = _gnoi_open(target)
        _gnoi_pool[target] = {"channel": channel, "stub": stub,
                              "last": time.monotonic()}
        log.info("gNOI pool: size=%d", len(_gnoi_pool))
        return stub


def _gnoi_drop(target):
    with _gnoi_pool_lock:
        entry = _gnoi_pool.pop(target, None)
    if entry:
        log.warning("gNOI pool: dropping channel %s", target)
        try: entry["channel"].close()
        except Exception: pass


def gnoi_set_crossconnect(host: str, port: int, state: bool) -> dict[str, Any]:
    target = f"{host}:{port}"
    log.info("gNOI SetCrossConnect target=%s state=%s", target, state)
    req = gnoi_pb2.CrossConnectRequest(state=bool(state))

    def _once():
        stub = _gnoi_acquire(target)
        return stub.SetCrossConnect(req, timeout=GNOI_TMO)

    try:
        resp = _once()
    except grpc.RpcError as e:
        if e.code() not in (grpc.StatusCode.UNAVAILABLE,
                            grpc.StatusCode.UNKNOWN):
            raise RuntimeError(
                f"gRPC SetCrossConnect failed: {e.code().name}: {e.details()}"
            )
        log.warning("gNOI SetCrossConnect failed (%s); reconnecting once",
                    e.code().name)
        _gnoi_drop(target)
        resp = _once()
    return {"success": resp.success, "message": resp.message}


def gnoi_get_crossconnect_status(host: str, port: int) -> dict[str, Any]:
    target = f"{host}:{port}"
    log.info("gNOI GetCrossConnectStatus target=%s", target)

    def _once():
        stub = _gnoi_acquire(target)
        return stub.GetCrossConnectStatus(gnoi_pb2.StatusRequest(),
                                          timeout=GNOI_TMO)

    try:
        resp = _once()
    except grpc.RpcError as e:
        if e.code() not in (grpc.StatusCode.UNAVAILABLE,
                            grpc.StatusCode.UNKNOWN):
            raise
        log.warning("gNOI status failed (%s); reconnecting once", e.code().name)
        _gnoi_drop(target)
        resp = _once()
    return {"is_connected": resp.is_connected, "switch_type": resp.switch_type}


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
                "pool": {
                    "enabled":          POOL_ENABLED,
                    "keepalive_s":      KEEPALIVE_INTERVAL,
                    "idle_ttl_s":       CONN_IDLE_TTL,
                    "max_per_pool":     CONN_MAX_POOL,
                    "netconf_open":     len(_netconf_pool),
                    "gnoi_open":        len(_gnoi_pool),
                },
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
