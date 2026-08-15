#!/bin/bash
# ---------------------------------------------------------------------------
# Quantum-SDN Switching Architecture Bootstrap Script
# ---------------------------------------------------------------------------

set -e # Exit immediately if a command exits with a non-zero status

# --- Colors for Output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- Helper Functions ---
log_info() { echo -e "${CYAN}[INFO] $1${NC}"; }
log_success() { echo -e "${GREEN}[SUCCESS] $1${NC}"; }
log_warn() { echo -e "${YELLOW}[WARNING] $1${NC}"; }
log_error() { echo -e "${RED}[ERROR] $1${NC}"; exit 1; }

ask_user() {
    local prompt="$1"
    local default="$2"
    local response

    if [ "$default" = "Y" ]; then
        read -p "$(echo -e "${YELLOW}${prompt} [Y/n]: ${NC}")" response
        response=${response:-Y}
    else
        read -p "$(echo -e "${YELLOW}${prompt} [y/N]: ${NC}")" response
        response=${response:-N}
    fi

    if [[ "$response" =~ ^[Yy]$ ]]; then
        return 0
    else
        return 1
    fi
}

# --- Phase 1: Repository Scaffolding ---
create_repo_structure() {
    log_info "Phase 1: Creating Quantum-SDN repository structure..."
    local base_dir="quantum-sdn-switching-architecture"

    if [ -d "$base_dir" ]; then
        log_warn "Directory '$base_dir' already exists."
        if ! ask_user "Do you want to recreate/update the folders inside it?" "Y"; then
            log_info "Skipping directory creation."
            return
        fi
    fi

    # Create directories with quoted variable pathing
    mkdir -p "$base_dir"/.github/workflows \
             "$base_dir"/docs/architecture \
             "$base_dir"/docs/api \
             "$base_dir"/deploy/vm-provisioning \
             "$base_dir"/deploy/k8s-cluster \
             "$base_dir"/sdn-controller/apps \
             "$base_dir"/sdn-controller/southbound-plugins \
             "$base_dir"/sdn-controller/northbound-interfaces \
             "$base_dir"/orchestration/osm-packages \
             "$base_dir"/orchestration/yang-models \
             "$base_dir"/workloads/open5gs \
             "$base_dir"/hardware-agents/gnoi-targets \
             "$base_dir"/hardware-agents/switch-drivers \
             "$base_dir"/tests/latency-benchmarks \
             "$base_dir"/tests/e2e-path-provisioning \
             "$base_dir"/scripts \
             "$base_dir"/proto

    # Create placeholder files cleanly
    touch "$base_dir/README.md"
    touch "$base_dir/LICENSE"
    touch "$base_dir/Makefile"

    log_success "Repository structure created successfully at ./$base_dir"
}

# --- Phase 2: System Dependencies ---
install_sys_deps() {
    log_info "Phase 2: Checking basic system dependencies (curl, git, wget, jq, python3-pip)..."
    # ADDED: python3-pip and python3-venv for the gRPC client phase
    local deps="curl git wget jq build-essential python3-pip python3-venv"
    local to_install=""

    for pkg in $deps; do
        if ! dpkg -l | grep -qw "$pkg"; then
            to_install="$to_install $pkg"
        fi
    done

    if [ -n "$to_install" ]; then
        log_info "Installing missing packages:$to_install"
        sudo apt-get update -y
        sudo apt-get install -y $to_install
        log_success "System dependencies installed."
    else
        log_success "All basic system dependencies are already installed."
    fi
}

# --- Phase 3: Docker & Kubernetes & Helm ---
install_docker() {
    log_info "Checking Docker..."
    if command -v docker >/dev/null 2>&1; then
        log_success "Docker is already installed ($(docker --version))."
        if ask_user "Do you want to attempt upgrading Docker?" "N"; then
            sudo apt-get update && sudo apt-get upgrade -y docker-ce
        fi
    else
        log_info "Installing Docker..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sudo sh get-docker.sh
        sudo usermod -aG docker "$USER"
        rm get-docker.sh
        log_success "Docker installed."
    fi
}

install_kubectl_and_helm() {
    log_info "Checking kubectl..."
    if command -v kubectl >/dev/null 2>&1; then
        log_success "kubectl is already installed."
    else
        log_info "Installing kubectl..."
        curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
        sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
        rm kubectl
        log_success "kubectl installed."
    fi

    log_info "Checking Helm..."
    if command -v helm >/dev/null 2>&1; then
        log_success "Helm is already installed ($(helm version --short))."
    else
        log_info "Installing Helm..."
        curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
        chmod 700 get_helm.sh
        ./get_helm.sh
        rm get_helm.sh
        log_success "Helm installed."
    fi
}

# --- Phase 4: SDN Controller (µONOS) & Open5GS Repos ---
setup_helm_repos() {
    log_info "Phase 4: Setting up Helm repositories for µONOS and Open5GS..."

    # microONOS Repo
    helm repo add onosproject https://charts.onosproject.org

    # Towards5GS (Using official Orange Towards5GS repo - Note: This is for Free5GC)
    helm repo add towards5gs https://raw.githubusercontent.com/Orange-OpenSource/towards5gs-helm/main/repo/

    helm repo update
    log_success "Helm repositories added and updated."
}

# --- Phase 5: gRPC & gNOI Tooling ---
install_grpc_tools() {
    log_info "Phase 5: Checking Protocol Buffers (protoc) for gNOI/gRPC development..."
    if command -v protoc >/dev/null 2>&1; then
        log_success "protoc is already installed ($(protoc --version))."
        if ask_user "Do you want to attempt upgrading protoc?" "N"; then
            sudo apt-get install -y protobuf-compiler
        fi
    else
        log_info "Installing Protocol Buffers Compiler..."
        sudo apt-get install -y protobuf-compiler
        log_success "protoc installed."
    fi

    log_info "Checking grpcurl..."
    if command -v grpcurl >/dev/null 2>&1; then
        log_success "grpcurl is already installed."
    else
        log_info "Installing grpcurl..."
        wget https://github.com/fullstorydev/grpcurl/releases/download/v1.8.7/grpcurl_1.8.7_linux_x86_64.tar.gz
        tar -xvf grpcurl_1.8.7_linux_x86_64.tar.gz
        sudo mv grpcurl /usr/local/bin/
        rm grpcurl_1.8.7_linux_x86_64.tar.gz LICENSE
        log_success "grpcurl installed."
    fi
}

# --- Phase 6: Orchestration (OSM) ---
install_osm_installer() {
    log_info "Phase 6: Open Source MANO (OSM)"
    log_warn "OSM is a highly complex orchestration platform requiring significant resources."

    if ask_user "Do you want to download and run the OSM standalone installer now?" "N"; then
        log_info "Downloading OSM installer..."
        wget https://osm-download.etsi.org/ftp/osm-14.0-fourteen/install_osm.sh
        chmod +x install_osm.sh
        log_info "Running OSM installer..."
        ./install_osm.sh
        log_success "OSM installation process finished."
    else
        log_info "Skipping OSM installation."
    fi
}

# --- Phase 7: Setup Python gRPC Client & Test Scripts ---
setup_sdn_python_client() {
    log_info "Phase 7: Setting up Python gRPC SDN Client..."
    local base_dir="quantum-sdn-switching-architecture"

    # 1. Generate the shared Protobuf definition
    log_info "Generating protobuf definition at $base_dir/proto/quantum_switch.proto..."
    cat <<EOF > "$base_dir/proto/quantum_switch.proto"
syntax = "proto3";

package quantum.switch.v1;

service QuantumSwitchService {
  rpc SetCrossConnect (CrossConnectRequest) returns (CrossConnectResponse);
  rpc GetCrossConnectStatus (StatusRequest) returns (StatusResponse);
}

message CrossConnectRequest {
  bool state = 1; // true = CONNECTED, false = DISCONNECTED
}

message CrossConnectResponse {
  bool success = 1;
  string message = 2;
}

message StatusRequest {}

message StatusResponse {
  bool is_connected = 1;
  string switch_type = 2;
}
EOF

    # 2. Install pip dependencies and compile proto
    log_info "Installing Python grpcio-tools and compiling stubs..."
    sudo pip3 install --upgrade pip
    sudo pip3 install grpcio grpcio-tools

    python3 -m grpc_tools.protoc -I"$base_dir/proto" \
        --python_out="$base_dir/proto" \
        --grpc_python_out="$base_dir/proto" \
        "$base_dir/proto/quantum_switch.proto"

    touch "$base_dir/proto/__init__.py"
    log_success "Stubs compiled successfully."

    # 3. Generate the general CLI Client in scripts/
    log_info "Creating CLI Client: $base_dir/scripts/sdn-switching-client.py..."
    cat <<'EOF' > "$base_dir/scripts/sdn-switching-client.py"
#!/usr/bin/env python3
import grpc
import argparse
import sys
import os

# Ensure the proto directory is discoverable relative to this script
current_dir = os.path.dirname(os.path.abspath(__file__))
proto_dir = os.path.abspath(os.path.join(current_dir, '../proto'))
sys.path.append(proto_dir)

import quantum_switch_pb2
import quantum_switch_pb2_grpc

class QuantumSDNClient:
    def __init__(self, host, port=50051):
        self.target = f"{host}:{port}"
        self.channel = grpc.insecure_channel(self.target)
        self.stub = quantum_switch_pb2_grpc.QuantumSwitchServiceStub(self.channel)

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
    parser.add_argument("node_ip", help="IP address of the BeagleBone node")
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
EOF
    chmod +x "$base_dir/scripts/sdn-switching-client.py"

    # 4. Generate the Automated Test Script in tests/
    log_info "Creating Test Script: $base_dir/tests/test-manual-sdn-switching.py..."
    cat <<'EOF' > "$base_dir/tests/test-manual-sdn-switching.py"
#!/usr/bin/env python3
import sys
import os
import time

# Ensure we can import the client from the scripts folder
current_dir = os.path.dirname(os.path.abspath(__file__))
scripts_dir = os.path.abspath(os.path.join(current_dir, '../scripts'))
sys.path.append(scripts_dir)

# Now we can import the class directly from the client file
client_module = __import__('sdn-switching-client')
QuantumSDNClient = client_module.QuantumSDNClient

def run_test(ip):
    print(f"\n--- Starting Automated Hardware Switching Test on {ip} ---")
    client = QuantumSDNClient(ip)
    
    print("\n[Step 1] Fetching initial status...")
    client.check_status()
    time.sleep(1)

    print("\n[Step 2] Triggering CONNECT...")
    client.set_connection(True)
    time.sleep(2)
    client.check_status()
    
    print("\n[Step 3] Triggering DISCONNECT...")
    client.set_connection(False)
    time.sleep(2)
    client.check_status()

    print("\n--- Test Sequence Complete ---\n")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: ./test-manual-sdn-switching.py <NODE_IP>")
        sys.exit(1)
    
    run_test(sys.argv[1])
EOF
    chmod +x "$base_dir/tests/test-manual-sdn-switching.py"
    log_success "Python SDN Client and Test scripts generated successfully."
}

# --- Main Execution ---
echo -e "${CYAN}===========================================================${NC}"
echo -e "${CYAN}   Quantum-SDN Switching Architecture Environment Setup    ${NC}"
echo -e "${CYAN}===========================================================${NC}"

create_repo_structure
install_sys_deps
install_docker
install_kubectl_and_helm
setup_helm_repos
install_grpc_tools
install_osm_installer
setup_sdn_python_client  # <--- NEW PHASE EXECUTED HERE

echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN} Setup Complete! ${NC}"
echo -e "Navigate to your repository: ${YELLOW}cd quantum-sdn-switching-architecture${NC}"
echo -e "Check Helm charts: ${YELLOW}helm search repo towards5gs${NC}"
echo -e "To run a client command: ${YELLOW}python3 scripts/sdn-switching-client.py <IP> status${NC}"
echo -e "To run a hardware test: ${YELLOW}python3 tests/test-manual-sdn-switching.py <IP>${NC}"
echo -e "${GREEN}====================================================${NC}"
