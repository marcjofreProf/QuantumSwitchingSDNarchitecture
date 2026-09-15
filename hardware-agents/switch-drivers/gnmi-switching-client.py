#!/usr/bin/env python3
import os
import sys
import argparse

current_dir = os.path.dirname(os.path.abspath(__file__))
repo_root = os.path.abspath(os.path.join(current_dir, "../.."))

# --- VENV AUTO-DISCOVERY & RE-EXECUTION ---
venv_dir = os.path.join(repo_root, ".venv")
venv_python = os.path.join(venv_dir, "bin", "python3")

# Re-execute if python is running outside the project's .venv
if os.path.isfile(venv_python) and os.path.abspath(sys.prefix) != os.path.abspath(venv_dir):
    os.execv(venv_python, [venv_python] + sys.argv)

try:
    import grpc
except ModuleNotFoundError:
    print("[ERROR] 'grpc' missing and no virtual environment found. Run the bootstrap script first.")
    sys.exit(1)

# Resolve proto directory
proto_dir = os.path.join(repo_root, "proto")

if proto_dir not in sys.path:
    sys.path.insert(0, proto_dir)

try:
    import gnmi_pb2
    import gnmi_pb2_grpc
except ModuleNotFoundError as e:
    print(f"[ERROR] Could not import gNMI Protobuf stubs from '{proto_dir}': {e}")
    print("[HINT] Ensure the bootstrap script has compiled gnmi.proto into gnmi_pb2.py.")
    sys.exit(1)

class QuantumGNMIClient:
    def __init__(self, host, port=50051):
        self.target = f"{host}:{port}"
        self.channel = grpc.insecure_channel(self.target)
        self.stub = gnmi_pb2_grpc.gNMIStub(self.channel)

    def check_status(self):
        print(f"[*] Querying gNMI status from {self.target}...")
        path = gnmi_pb2.Path()
        request = gnmi_pb2.GetRequest(path=[path], encoding=gnmi_pb2.JSON)
        try:
            response = self.stub.Get(request, timeout=5)
            val = "UNKNOWN"
            if response.notification:
                for notification in response.notification:
                    for update in notification.update:
                        val = update.val.string_val or update.val.json_val.decode('utf-8')
            print(f"    -> gNMI Switch State: {val}")
            return val
        except grpc.RpcError as e:
            print(f"    -> [ERROR] gNMI Get: {e.code()} - {e.details()}")
            sys.exit(1)

    def set_connection(self, connect: bool):
        target_state = "ENABLED" if connect else "DISABLED"
        action = "CONNECTING" if connect else "DISCONNECTING"
        print(f"[*] {action} node via gNMI at {self.target}...")
        
        path = gnmi_pb2.Path()
        typed_val = gnmi_pb2.TypedValue(string_val=target_state)
        update_op = gnmi_pb2.Update(path=path, val=typed_val)
        
        request = gnmi_pb2.SetRequest(update=[update_op])
        try:
            response = self.stub.Set(request, timeout=5)
            print(f"    -> SUCCESS: State updated to '{target_state}' (Timestamp: {response.timestamp})")
        except grpc.RpcError as e:
            print(f"    -> [ERROR] gNMI Set: {e.code()} - {e.details()}")
            sys.exit(1)

def main():
    parser = argparse.ArgumentParser(description="Quantum SDN gNMI Switching Client")
    parser.add_argument("node_ip", help="IP address of the remote switch node")
    parser.add_argument("command", choices=["status", "connect", "disconnect"], 
                        help="Action to perform on the remote node")
    parser.add_argument("--port", type=int, default=50051, 
                        help="gRPC port (default: 50051)")

    args = parser.parse_args()
    client = QuantumGNMIClient(args.node_ip, args.port)

    if args.command == "status":
        client.check_status()
    elif args.command == "connect":
        client.set_connection(True)
    elif args.command == "disconnect":
        client.set_connection(False)

if __name__ == "__main__":
    main()
