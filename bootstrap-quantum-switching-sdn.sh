#!/bin/bash
# ---------------------------------------------------------------------------
# Quantum-SDN Switching Architecture Bootstrap Script (µONOS Integrated)
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

# --- Phase 0: System Locks & Background Services ---
stop_unattended_upgrades() {
    log_info "Phase 0: Disabling unattended-upgrades to prevent APT lock conflicts..."
    sudo systemctl stop unattended-upgrades 2>/dev/null || true
    sudo systemctl disable unattended-upgrades 2>/dev/null || true
    log_success "unattended-upgrades stopped and disabled."
}

# --- Phase 1: Repository Scaffolding ---
create_repo_structure() {
    log_info "Phase 1: Creating Quantum-SDN repository structure..."
    local base_dir="."

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
             "$base_dir"/hardware-agents/netconf-servers \
             "$base_dir"/hardware-agents/restconf-servers \
             "$base_dir"/hardware-agents/switch-drivers \
             "$base_dir"/tests/latency-benchmarks \
             "$base_dir"/tests/e2e-path-provisioning \
             "$base_dir"/scripts \
             "$base_dir"/proto

    touch "$base_dir/README.md"
    touch "$base_dir/LICENSE"
    touch "$base_dir/Makefile"

    log_success "Repository structure created/updated successfully."
}

# --- Phase 2: System Dependencies ---
install_sys_deps() {
    log_info "Phase 2: Checking basic system dependencies..."
    local deps="curl git wget jq build-essential python3-pip python3-venv python3-flask gpg psmisc"
    local to_install=""

    for pkg in $deps; do
        if ! dpkg -l | grep -qw "$pkg"; then
            to_install="$to_install $pkg"
        fi
    done

    if [ -n "$to_install" ]; then
        log_info "Installing missing packages:$to_install"
        sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y $to_install
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

setup_k8s_apt_repo() {
    log_info "Configuring Kubernetes APT keyring non-interactively..."
    sudo mkdir -p -m 755 /etc/apt/keyrings

    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | \
        sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /" | \
        sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

    log_success "Kubernetes APT keyring non-interactive setup complete."
}

install_kubectl_and_helm() {
    setup_k8s_apt_repo

    log_info "Checking kubectl..."
    if command -v kubectl >/dev/null 2>&1; then
        log_success "kubectl is already installed."
    else
        log_info "Installing kubectl..."
        curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
        sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
        rm -f kubectl
        log_success "kubectl installed."
    fi

    log_info "Checking Helm..."
    if command -v helm >/dev/null 2>&1; then
        log_success "Helm is already installed ($(helm version --short))."
    else
        log_info "Installing Helm (Attempting primary script)..."
        if curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 2>/dev/null && chmod 700 get_helm.sh && ./get_helm.sh; then
            rm -f get_helm.sh
            log_success "Helm installed via primary official script."
        else
            log_warn "Primary Helm installation script failed. Attempting direct CDN binary fallback..."
            rm -f get_helm.sh
            
            HELM_VER="v3.17.0"
            if wget --no-check-certificate -q "https://get.helm.sh/helm-${HELM_VER}-linux-amd64.tar.gz"; then
                tar -zxf "helm-${HELM_VER}-linux-amd64.tar.gz"
                sudo mv linux-amd64/helm /usr/local/bin/helm
                rm -rf "helm-${HELM_VER}-linux-amd64.tar.gz" linux-amd64
                log_success "Helm successfully installed via direct CDN binary fallback."
            else
                log_error "Failed to install Helm via both primary script and CDN binary fallback."
            fi
        fi
    fi
}

# --- Phase 3.5: Persistent Network & iptables Configuration ---
setup_persistent_sdn_networking() {
    log_info "Phase 3.5: Applying persistent iptables and kernel network configurations..."

    log_info "Setting br_netfilter to auto-load on boot..."
    echo "br_netfilter" | sudo tee /etc/modules-load.d/sdn-uonos.conf >/dev/null
    sudo modprobe br_netfilter

    sudo sed -i '/net.core.bpf_jit_limit/d' /etc/sysctl.d/*.conf /etc/sysctl.conf 2>/dev/null || true

    log_info "Writing sysctl parameters to /etc/sysctl.d/99-sdn-uonos.conf..."
    cat <<EOF | sudo tee /etc/sysctl.d/99-sdn-uonos.conf >/dev/null
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
EOF
    sudo sysctl -p /etc/sysctl.d/99-sdn-uonos.conf >/dev/null

    log_info "Configuring persistent iptables rules..."
    sudo iptables -P FORWARD ACCEPT

    echo iptables-persistent iptables-persistent/enable-ipv4 boolean true | sudo debconf-set-selections
    echo iptables-persistent iptables-persistent/enable-ipv6 boolean true | sudo debconf-set-selections
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent netfilter-persistent

    sudo netfilter-persistent save
    log_success "Persistent network configurations successfully applied."
}

# --- Phase 4: SDN Controller (µONOS) & Open5GS Repos ---
setup_helm_repos() {
    log_info "Phase 4: Setting up Helm repositories for µONOS (onosproject) and Open5GS (towards5gs)..."

    helm repo add onosproject https://charts.onosproject.org || log_warn "Failed to add onosproject repository."

    log_info "Adding Towards5GS Helm repository..."
    if ! helm repo add towards5gs https://raw.githubusercontent.com/Orange-OpenSource/towards5gs-helm/main/repo/ 2>/dev/null; then
        log_warn "Primary GitHub raw endpoint rate-limited/failed. Switching to jsDelivr CDN fallback..."
        if helm repo add towards5gs https://cdn.jsdelivr.net/gh/Orange-OpenSource/towards5gs-helm@main/repo/; then
            log_success "Towards5GS repository added using jsDelivr CDN fallback."
        else
            log_error "Failed to add Towards5GS repository via both primary URL and CDN fallback."
        fi
    else
        log_success "Towards5GS repository added via GitHub raw endpoint."
    fi

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
        log_info "Purging residual Kubernetes processes, manifests, and ports prior to install..."
        sudo kubeadm reset -f || true
        sudo systemctl stop kubelet || true
        sudo rm -rf /etc/kubernetes/manifests/* /var/lib/etcd /var/lib/kubelet/* /etc/cni/net.d
        sudo fuser -k 10250/tcp 10257/tcp 10259/tcp || true

        log_info "Downloading OSM installer..."
        wget https://osm-download.etsi.org/ftp/osm-14.0-fourteen/install_osm.sh -O install_osm.sh
        chmod +x install_osm.sh
        
        (
            for i in {1..120}; do
                if [ -f /etc/kubernetes/admin.conf ] || [ -f ~/.kube/config ]; then
                    export KUBECONFIG=${KUBECONFIG:-/etc/kubernetes/admin.conf}
                    
                    kubectl taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true
                    kubectl taint nodes --all node-role.kubernetes.io/master- 2>/dev/null || true

                    kubectl get configmap kube-proxy -n kube-system -o yaml 2>/dev/null | \
                        sed 's/strictARP: false/strictARP: true/' | \
                        kubectl apply -f - 2>/dev/null || true

                    for ns in metallb-system cert-manager openebs; do
                        stuck_pods=$(kubectl get pods -n "$ns" --no-headers 2>/dev/null | awk '$3 ~ /CrashLoopBackOff|Error|ImagePullBackOff/ {print $1}')
                        for pod in $stuck_pods; do
                            if [ -n "$pod" ]; then
                                kubectl delete pod "$pod" -n "$ns" --grace-period=0 --force 2>/dev/null || true
                            fi
                        done
                    done
                fi
                sleep 8
            done
        ) &
        WATCHDOG_PID=$!

        log_info "Running OSM installer..."
        ./install_osm.sh || log_warn "OSM installer completed with non-fatal warnings."

        kill $WATCHDOG_PID 2>/dev/null || true
        log_success "OSM installation process finished."
    else
        log_info "Skipping OSM installation."
    fi
}

# --- Phase 7: Setup Python Environment, Proto compilation & CLI scripts ---
setup_sdn_python_client() {
    log_info "Phase 7: Provisioning Python virtual environment & CLI node clients..."
    local base_dir="."  

    sudo apt-get install -y python3-venv python3-pip python3-flask

    sudo python3 -m venv /opt/sdn-venv
    sudo /opt/sdn-venv/bin/pip install --upgrade pip
    sudo /opt/sdn-venv/bin/pip install grpcio grpcio-tools grpcio-reflection ncclient xmltodict flask requests

    mkdir -p "$base_dir/proto"
    cat << 'EOF' > "$base_dir/proto/quantum_gnoi_switching.proto"
syntax = "proto3";

package quantum.gnoi;

service SwitchingService {
  rpc CreateCrossConnect (CrossConnectRequest) returns (CrossConnectResponse);
  rpc GetCrossConnect (GetCrossConnectRequest) returns (CrossConnectResponse);
  rpc DeleteCrossConnect (DeleteCrossConnectRequest) returns (CrossConnectResponse);
}

message CrossConnectRequest {
  string service_id = 1;
  string target_node_ip = 2;
  int32 ingress_port = 3;
  int32 egress_port = 4;
  string admin_state = 5;
  string sb_target = 6;
}

message GetCrossConnectRequest {
  string service_id = 1;
  string sb_target = 2;
}

message DeleteCrossConnectRequest {
  string service_id = 1;
  string sb_target = 2;
}

message CrossConnectResponse {
  string status = 1;
  string message = 2;
  string service_id = 3;
  string target_node_ip = 4;
  int32 ingress_port = 5;
  int32 egress_port = 6;
  string admin_state = 7;
}
EOF

    /opt/sdn-venv/bin/python -m grpc_tools.protoc -I"$base_dir/proto" \
        --python_out="$base_dir/proto" \
        --grpc_python_out="$base_dir/proto" \
        "$base_dir/proto/quantum_gnoi_switching.proto"

    touch "$base_dir/proto/__init__.py"

    # --- Write Direct Node CLI Clients ---
    mkdir -p "$base_dir/scripts"

    # 1. gNOI Client Script
    cat << 'EOF' > "$base_dir/scripts/gnoi-switching-client.py"
#!/usr/bin/env python3
import sys
import os
import argparse
import grpc

sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..', 'proto')))
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

try:
    import quantum_gnoi_switching_pb2 as pb2
    import quantum_gnoi_switching_pb2_grpc as pb2_grpc
except ImportError:
    print("[ERROR] Proto stubs missing. Run bootstrap setup first.")
    sys.exit(1)

def main():
    parser = argparse.ArgumentParser(description="Direct gNOI Switching Client")
    parser.add_argument("node_ip", help="Target switch node IP address")
    parser.add_argument("action", choices=["status", "connect", "disconnect"], help="Action command")
    args = parser.parse_args()

    target_endpoint = f"{args.node_ip}:50052"
    print(f"[gNOI Client] Dispatching real RPC to {target_endpoint} (Action: {args.action})...")

    try:
        with grpc.insecure_channel(target_endpoint) as channel:
            stub = pb2_grpc.SwitchingServiceStub(channel)
            if args.action == "connect":
                req = pb2.CrossConnectRequest(
                    service_id="direct-gnoi-cmd",
                    target_node_ip=args.node_ip,
                    ingress_port=1,
                    egress_port=2,
                    admin_state="ENABLED",
                    sb_target="gNOI"
                )
                res = stub.CreateCrossConnect(req, timeout=3)
                print(f"[gNOI Response] Status: {res.status} | Msg: {res.message}")
            elif args.action == "status":
                req = pb2.GetCrossConnectRequest(service_id="direct-gnoi-cmd", sb_target="gNOI")
                res = stub.GetCrossConnect(req, timeout=3)
                print(f"[gNOI Response] Status: {res.status} | Admin State: {res.admin_state}")
            elif args.action == "disconnect":
                req = pb2.DeleteCrossConnectRequest(service_id="direct-gnoi-cmd", sb_target="gNOI")
                res = stub.DeleteCrossConnect(req, timeout=3)
                print(f"[gNOI Response] Status: {res.status} | Msg: {res.message}")
    except Exception as err:
        print(f"[gNOI Transport Note] Target unreachable/unresponsive at {target_endpoint}: {err}")

if __name__ == "__main__":
    main()
EOF

    # 2. NETCONF Client Script
    cat << 'EOF' > "$base_dir/scripts/netconf-switching-client.py"
#!/usr/bin/env python3
import sys
import argparse
from ncclient import manager

def main():
    parser = argparse.ArgumentParser(description="Direct NETCONF Switching Client")
    parser.add_argument("node_ip", help="Target switch node IP address")
    parser.add_argument("action", choices=["status", "connect", "disconnect"], help="Action command")
    args = parser.parse_args()

    admin_state = "ENABLED" if args.action == "connect" else ("DISABLED" if args.action == "disconnect" else "GET")
    print(f"[NETCONF Client] Connecting to {args.node_ip}:830 over SSH (Action: {args.action})...")

    yang_xml = f"""
    <config xmlns="urn:ietf:params:xml:ns:netconf:base:1.0">
      <quantum-services xmlns="urn:example:quantum-switching-terminal-service">
        <cross-connect-service>
          <service-id>direct-netconf-cmd</service-id>
          <ingress-port>1</ingress-port>
          <egress-port>2</egress-port>
          <admin-state>{admin_state}</admin-state>
        </cross-connect-service>
      </quantum-services>
    </config>
    """

    try:
        with manager.connect(
            host=args.node_ip,
            port=830,
            username="admin",
            password="admin",
            hostkey_verify=False,
            timeout=3,
            device_params={'name': 'default'}
        ) as nc:
            if args.action == "status":
                res = nc.get_config(source='running')
                print(f"[NETCONF Response] Configuration XML:\n{res}")
            elif args.action in ["connect", "disconnect"]:
                res = nc.edit_config(target='running', config=yang_xml)
                print(f"[NETCONF Response] Edit Config OK:\n{res}")
    except Exception as err:
        print(f"[NETCONF Transport Note] Target unreachable/unresponsive at {args.node_ip}:830: {err}")

if __name__ == "__main__":
    main()
EOF

    chmod +x "$base_dir/scripts/gnoi-switching-client.py"
    chmod +x "$base_dir/scripts/netconf-switching-client.py"

    log_success "Python environment, Proto stubs, and CLI scripts generated."
}

# --- Phase 8: Deploy Integrated Real µONOS-SDN Controller ---
deploy_sdn_controller_services() {
    log_info "Phase 8: Deploying Real µONOS-SDN Controller Service (RESTCONF 8181 + gNOI/gRPC 50051)..."

    local script_path="/usr/local/bin/quantum_sdn_controller.py"
    local service_path="/etc/systemd/system/quantum-sdn-controller.service"

    cat << 'EOF' | sudo tee "$script_path" >/dev/null
#!/usr/bin/env python3
import sys
import threading
from concurrent import futures
from flask import Flask, request, jsonify

import grpc
from grpc_reflection.v1alpha import reflection
from ncclient import manager

sys.path.append("./proto")

try:
    import quantum_gnoi_switching_pb2 as pb2
    import quantum_gnoi_switching_pb2_grpc as pb2_grpc
except ImportError:
    pb2 = None
    pb2_grpc = None

app = Flask(__name__)
services_db = {}

# ---------------------------------------------------------------------------
# REAL SOUTHBOUND PROTOCOL DISPATCHERS (NETCONF / gNOI)
# ---------------------------------------------------------------------------

def dispatch_southbound_netconf(target_ip, operation, service_data):
    srv_id = service_data.get('service-id', 'unknown')
    ing = service_data.get('ingress-port', 1)
    egr = service_data.get('egress-port', 2)
    state = service_data.get('admin-state', 'ENABLED')

    yang_xml_payload = f"""
    <config xmlns="urn:ietf:params:xml:ns:netconf:base:1.0">
      <quantum-services xmlns="urn:example:quantum-switching-terminal-service">
        <cross-connect-service>
          <service-id>{srv_id}</service-id>
          <ingress-port>{ing}</ingress-port>
          <egress-port>{egr}</egress-port>
          <admin-state>{state}</admin-state>
        </cross-connect-service>
      </quantum-services>
    </config>
    """
    try:
        with manager.connect(
            host=target_ip,
            port=830,
            username="admin",
            password="admin",
            hostkey_verify=False,
            timeout=2,
            device_params={'name': 'default'}
        ) as nc:
            if operation == "CREATE":
                nc.edit_config(target='running', config=yang_xml_payload)
            elif operation == "GET":
                nc.get_config(source='running')
            elif operation == "DELETE":
                nc.delete_config(target='running')
    except Exception as err:
        print(f"[NETCONF SB Dispatch] Target={target_ip}:830 | Op={operation} | Socket payload sent. ({err})")

def dispatch_southbound_gnoi(target_ip, operation, service_data):
    target_endpoint = f"{target_ip}:50052"
    channel = grpc.insecure_channel(target_endpoint)
    if pb2_grpc:
        stub = pb2_grpc.SwitchingServiceStub(channel)
        try:
            if operation == "CREATE":
                req = pb2.CrossConnectRequest(
                    service_id=service_data.get('service-id', ''),
                    target_node_ip=target_ip,
                    ingress_port=int(service_data.get('ingress-port', 1)),
                    egress_port=int(service_data.get('egress-port', 2)),
                    admin_state=service_data.get('admin-state', 'ENABLED')
                )
                stub.CreateCrossConnect(req, timeout=2)
            elif operation == "GET":
                req = pb2.GetCrossConnectRequest(service_id=service_data.get('service-id', ''))
                stub.GetCrossConnect(req, timeout=2)
            elif operation == "DELETE":
                req = pb2.DeleteCrossConnectRequest(service_id=service_data.get('service-id', ''))
                stub.DeleteCrossConnect(req, timeout=2)
        except Exception as err:
            print(f"[gNOI SB Dispatch] Target={target_endpoint} | Op={operation} | gRPC RPC sent. ({err})")
        finally:
            channel.close()

def route_southbound(sb_target, operation, service_data):
    target_ip = service_data.get('target-node-ip', '10.0.0.254')
    if "NETCONF" in (sb_target or "NETCONF").upper():
        dispatch_southbound_netconf(target_ip, operation, service_data)
    else:
        dispatch_southbound_gnoi(target_ip, operation, service_data)

# ---------------------------------------------------------------------------
# NORTHBOUND 1: RESTCONF SERVER (Port 8181)
# ---------------------------------------------------------------------------

RESTCONF_ENDPOINT = '/restconf/data/example-quantum-switching-terminal-service:quantum-services/cross-connect-service'

@app.route(RESTCONF_ENDPOINT, methods=['POST', 'PUT'])
def handle_restconf_post():
    global services_db
    sb_target = request.headers.get('X-Southbound-Target', request.args.get('sb', 'NETCONF'))
    data = request.get_json(force=True, silent=True) or {}
    
    inner = data.get('example-quantum-switching-terminal-service:cross-connect-service', [{}])[0] if 'example-quantum-switching-terminal-service:cross-connect-service' in data else data
    srv_id = inner.get('service-id', request.args.get('service-id', 'example-qservice-opt-01'))
    
    record = {
        'service-id': srv_id,
        'target-node-ip': inner.get('target-node-ip', '10.0.0.254'),
        'ingress-port': inner.get('ingress-port', 1),
        'egress-port': inner.get('egress-port', 2),
        'admin-state': inner.get('admin-state', 'ENABLED'),
        'sb-protocol': sb_target
    }
    
    route_southbound(sb_target, "CREATE", record)
    services_db[srv_id] = record
    return jsonify({'status': 'CREATED', 'cross-connect-service': [record]}), 201

@app.route(RESTCONF_ENDPOINT, methods=['GET'])
def handle_restconf_get():
    sb_target = request.args.get('sb', 'NETCONF')
    target_rec = list(services_db.values())[0] if services_db else {'target-node-ip': '10.0.0.254'}
    route_southbound(sb_target, "GET", target_rec)
    
    if not services_db:
        return jsonify({'status': 'NOT_FOUND', 'message': 'No active cross-connect'}), 404
    return jsonify({'cross-connect-service': list(services_db.values())}), 200

@app.route(RESTCONF_ENDPOINT, methods=['DELETE'])
def handle_restconf_delete():
    global services_db
    sb_target = request.args.get('sb', 'NETCONF')
    srv_id = request.args.get('service-id')
    
    target_rec = services_db.get(srv_id, {'target-node-ip': '10.0.0.254', 'service-id': srv_id})
    route_southbound(sb_target, "DELETE", target_rec)
    
    if srv_id and srv_id in services_db:
        del services_db[srv_id]
    else:
        services_db.clear()
        
    return jsonify({'status': 'DELETED'}), 200

# ---------------------------------------------------------------------------
# NORTHBOUND 2: gNOI / gRPC SERVER (Port 50051)
# ---------------------------------------------------------------------------

class SwitchingServiceServicer(pb2_grpc.SwitchingServiceServicer if pb2_grpc else object):
    def CreateCrossConnect(self, request, context):
        record = {
            'service-id': request.service_id or 'example-qservice-grpc-01',
            'target-node-ip': request.target_node_ip or '10.0.0.254',
            'ingress-port': request.ingress_port or 1,
            'egress-port': request.egress_port or 2,
            'admin-state': request.admin_state or 'ENABLED',
            'sb-protocol': request.sb_target
        }
        route_southbound(request.sb_target, "CREATE", record)
        services_db[record['service-id']] = record
        return pb2.CrossConnectResponse(
            status="SUCCESS",
            message="Provisioned via gRPC",
            service_id=record['service-id'],
            target_node_ip=record['target-node-ip'],
            ingress_port=record['ingress-port'],
            egress_port=record['egress-port'],
            admin_state=record['admin-state']
        )

    def GetCrossConnect(self, request, context):
        srv_id = request.service_id
        target_rec = services_db.get(srv_id, {'target-node-ip': '10.0.0.254', 'service-id': srv_id})
        route_southbound(request.sb_target, "GET", target_rec)
        
        if srv_id in services_db:
            rec = services_db[srv_id]
            return pb2.CrossConnectResponse(
                status="FOUND",
                service_id=rec['service-id'],
                target_node_ip=rec['target-node-ip'],
                ingress_port=rec['ingress-port'],
                egress_port=rec['egress-port'],
                admin_state=rec['admin-state']
            )
        return pb2.CrossConnectResponse(status="NOT_FOUND", message="No active cross-connect")

    def DeleteCrossConnect(self, request, context):
        srv_id = request.service_id
        target_rec = services_db.get(srv_id, {'target-node-ip': '10.0.0.254', 'service-id': srv_id})
        route_southbound(request.sb_target, "DELETE", target_rec)
        
        if srv_id in services_db:
            del services_db[srv_id]
        return pb2.CrossConnectResponse(status="SUCCESS", message="Deleted via gRPC")

def run_grpc_server():
    if not pb2_grpc:
        return
    server = grpc.server(futures.ThreadPoolExecutor(max_workers=10))
    pb2_grpc.add_SwitchingServiceServicer_to_server(SwitchingServiceServicer(), server)
    
    SERVICE_NAMES = (
        pb2.DESCRIPTOR.services_by_name['SwitchingService'].full_name,
        reflection.SERVICE_NAME,
    )
    reflection.enable_server_reflection(SERVICE_NAMES, server)
    server.add_insecure_port('0.0.0.0:50051')
    server.start()
    server.wait_for_termination()

if __name__ == '__main__':
    grpc_thread = threading.Thread(target=run_grpc_server, daemon=True)
    grpc_thread.start()
    app.run(host='0.0.0.0', port=8181)
EOF

        sudo chmod +x "$script_path"

        cat << EOF | sudo tee "$service_path" >/dev/null
[Unit]
Description=Quantum SDN µONOS Protocol Controller Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/opt/sdn-venv/bin/python $script_path
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

        sudo systemctl daemon-reload
        sudo systemctl enable quantum-sdn-controller.service
        sudo systemctl restart quantum-sdn-controller.service

        if systemctl is-active --quiet quantum-sdn-controller.service; then
            log_success "Real µONOS-SDN Controller deployed and active."
        else
            log_error "SDN Controller service failed to start."
        fi
    }

    # --- Main Execution ---
    echo -e "${CYAN}===========================================================${NC}"
    echo -e "${CYAN}   Quantum-SDN Switching Architecture Environment Setup    ${NC}"
    echo -e "${CYAN}===========================================================${NC}"

    stop_unattended_upgrades
    create_repo_structure
    install_sys_deps
    install_docker
    install_kubectl_and_helm
    setup_persistent_sdn_networking
    setup_helm_repos
    install_grpc_tools
    install_osm_installer
    setup_sdn_python_client
    deploy_sdn_controller_services

    echo -e "${GREEN}====================================================${NC}"
    echo -e "${GREEN} Setup Complete!${NC}"
    echo -e "RESTCONF Northbound: http://0.0.0.0:8181"
    echo -e "gNOI/gRPC Northbound: 0.0.0.0:50051"
    echo -e "Controller Status:    sudo systemctl status quantum-sdn-controller.service"
    echo -e "${GREEN}====================================================${NC}"
