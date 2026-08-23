#!/usr/bin/env python3
import os
import sys

# Define this first so it's always available!
current_dir = os.path.dirname(os.path.abspath(__file__))

# --- ELEGANT VENV AUTO-DISCOVERY ---
try:
    import grpc
except ModuleNotFoundError:
    venv_python = os.path.abspath(os.path.join(current_dir, '../.venv/bin/python3'))
    if os.path.exists(venv_python):
        os.execl(venv_python, venv_python, *sys.argv) # Relaunch self inside venv
    else:
        print("[ERROR] 'grpc' missing and '.venv' not found. Run the bootstrap script first.")
        sys.exit(1)

import argparse

# Ensure the proto directory is discoverable relative to this script
proto_dir = os.path.abspath(os.path.join(current_dir, '../proto'))
sys.path.append(proto_dir)

import quantum_gnoi_switching_pb2 as pb2
import quantum_gnoi_switching_pb2_grpc as pb2_grpc

class QuantumSDNClient:
    def __init__(self, host, port=50051):
        self.target = f"{host}:{port}"
        self.channel = grpc.insecure_channel(self.target)
        self.stub = pb2_grpc.QuantumGnoiSwitchingServiceStub(channel)

    def check_status(self):
        print(f"[*] Querying status from {self.target}...")
        request = quantum_switch_pb2.StatusRequest()
        try:
            response = self.stub.GetCrossConnectStatus(request, timeout=5)
            state = "CONNECTED" if response.is_connected else "DISCONNECTED"
            print(f"    -> Status: {state} | Hardware Type: {response.switch_type}")
            return response.is_connected
        except grpc.RpcError as e:
            print(f"    -> [ERROR] gRPC: {e.code()} - {e.details()}")
            sys.exit(1)

    def set_connection(self, connect: bool):
        action = "CONNECTING" if connect else "DISCONNECTING"
        print(f"[*] {action} node at {self.target}...")
        request = quantum_switch_pb2.CrossConnectRequest(state=connect)
        try:
            response = self.stub.SetCrossConnect(request, timeout=5)
            if response.success:
                print(f"    -> SUCCESS: {response.message}")
            else:
                print(f"    -> FAILED: {response.message}")
        except grpc.RpcError as e:
            print(f"    -> [ERROR] gRPC: {e.code()} - {e.details()}")
            sys.exit(1)

def main():
    parser = argparse.ArgumentParser(description="Quantum SDN Orchestrator CLI Client")
    parser.add_argument("node_ip", help="IP address of the remote switch node")
    parser.add_argument("command", choices=["status", "connect", "disconnect"], 
                        help="Action to perform on the remote node")
    parser.add_argument("--port", type=int, default=50051, 
                        help="gRPC port (default: 50051)")

    args = parser.parse_args()
    client = QuantumSDNClient(args.node_ip, args.port)

    if args.command == "status":
        client.check_status()
    elif args.command == "connect":
        client.set_connection(True)
    elif args.command == "disconnect":
        client.set_connection(False)

if __name__ == "__main__":
    main()
