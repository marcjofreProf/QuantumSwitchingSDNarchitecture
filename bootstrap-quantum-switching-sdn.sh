#!/bin/bash
# ---------------------------------------------------------------------------
# Quantum-SDN Switching Architecture Bootstrap Script (Cloud-Native µONOS)
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
    log_info "Phase 0: Disabling unattended-upgrades to prevent APT lock conflicts..."[cite: 4]
    sudo systemctl stop unattended-upgrades 2>/dev/null || true
    sudo systemctl disable unattended-upgrades 2>/dev/null || true
    log_success "unattended-upgrades stopped and disabled."[cite: 4]
}

# --- Phase 1: Repository Scaffolding ---
create_repo_structure() {
    log_info "Phase 1: Creating Quantum-SDN repository structure..."[cite: 4]
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
             "$base_dir"/proto[cite: 4]

    touch "$base_dir/README.md"
    touch "$base_dir/LICENSE"
    touch "$base_dir/Makefile"

    log_success "Repository structure created/updated successfully."[cite: 4]
}

# --- Phase 2: System Dependencies ---
install_sys_deps() {
    log_info "Phase 2: Checking basic system dependencies..."[cite: 4]
    local deps="curl git wget jq build-essential python3-pip python3-venv python3-flask gpg psmisc"[cite: 4]
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
        log_success "System dependencies installed."[cite: 4]
    else
        log_success "All basic system dependencies are already installed."[cite: 4]
    fi
}

# --- Phase 3: Docker, Kubernetes Tools & Local K8s Cluster ---
install_docker() {
    log_info "Checking Docker..."[cite: 4]
    if command -v docker >/dev/null 2>&1; then
        log_success "Docker is already installed ($(docker --version))."[cite: 4]
    else
        log_info "Installing Docker..."
        curl -fsSL https://get.docker.com -o get-docker.sh
        sudo sh get-docker.sh
        sudo usermod -aG docker "$USER"
        rm get-docker.sh
        log_success "Docker installed."[cite: 4]
    fi
}

install_kubectl_and_helm() {
    log_info "Configuring Kubernetes APT keyring non-interactively..."[cite: 4]
    sudo mkdir -p -m 755 /etc/apt/keyrings
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | \
        sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg[cite: 4]
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /" | \
        sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null[cite: 4]

    if ! command -v kubectl >/dev/null 2>&1; then
        log_info "Installing kubectl..."
        sudo DEBIAN_FRONTEND=noninteractive apt-get update -y && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y kubectl
    fi

    if ! command -v helm >/dev/null 2>&1; then
        log_info "Installing Helm..."
        curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 && chmod 700 get_helm.sh && ./get_helm.sh[cite: 4]
        rm -f get_helm.sh
    fi
}

ensure_kubernetes_cluster() {
    log_info "Verifying active Kubernetes cluster for µONOS deployment..."
    if ! sudo kubectl cluster-info >/dev/null 2>&1; then
        log_warn "No active Kubernetes cluster found. Installing lightweight K3s cluster for testing..."
        curl -sfL https://get.k3s.io | sh -
        mkdir -p ~/.kube
        sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
        sudo chown $(id -u):$(id -g) ~/.kube/config
        log_success "Local K3s Kubernetes cluster deployed."
    else
        log_success "Kubernetes cluster is reachable."
    fi
}

# --- Phase 3.5: Persistent Network & iptables Configuration ---
setup_persistent_sdn_networking() {
    log_info "Phase 3.5: Applying persistent iptables and kernel network configurations..."[cite: 4]
    echo "br_netfilter" | sudo tee /etc/modules-load.d/sdn-uonos.conf >/dev/null[cite: 4]
    sudo modprobe br_netfilter

    sudo sed -i '/net.core.bpf_jit_limit/d' /etc/sysctl.d/*.conf /etc/sysctl.conf 2>/dev/null || true

    cat <<EOF | sudo tee /etc/sysctl.d/99-sdn-uonos.conf >/dev/null
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
EOF
    sudo sysctl -p /etc/sysctl.d/99-sdn-uonos.conf >/dev/null[cite: 4]
    sudo iptables -P FORWARD ACCEPT

    echo iptables-persistent iptables-persistent/enable-ipv4 boolean true | sudo debconf-set-selections[cite: 4]
    echo iptables-persistent iptables-persistent/enable-ipv6 boolean true | sudo debconf-set-selections[cite: 4]
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent netfilter-persistent

    sudo netfilter-persistent save[cite: 4]
}

# --- Phase 4: SDN Controller (µONOS) & Open5GS Repos ---
setup_helm_repos() {
    log_info "Phase 4: Setting up Helm repositories for µONOS (onosproject) and Open5GS (towards5gs)..."[cite: 4]
    helm repo add onosproject https://charts.onosproject.org || log_warn "Failed to add onosproject repository."[cite: 4]
    helm repo add towards5gs https://raw.githubusercontent.com/Orange-OpenSource/towards5gs-helm/main/repo/ || \
        helm repo add towards5gs https://cdn.jsdelivr.net/gh/Orange-OpenSource/towards5gs-helm@main/repo/[cite: 4]
    helm repo update[cite: 4]
}

# --- Phase 5: gRPC & gNOI Tooling ---
install_grpc_tools() {
    log_info "Phase 5: Checking Protocol Buffers (protoc) for gNOI/gRPC development..."[cite: 4]
    if ! command -v protoc >/dev/null 2>&1; then
        sudo apt-get install -y protobuf-compiler[cite: 4]
    fi
    if ! command -v grpcurl >/dev/null 2>&1; then
        wget https://github.com/fullstorydev/grpcurl/releases/download/v1.8.7/grpcurl_1.8.7_linux_x86_64.tar.gz[cite: 4]
        tar -xvf grpcurl_1.8.7_linux_x86_64.tar.gz
        sudo mv grpcurl /usr/local/bin/
        rm grpcurl_1.8.7_linux_x86_64.tar.gz LICENSE
    fi
}

# --- Phase 6: Orchestration (OSM) ---
install_osm_installer() {
    log_info "Phase 6: Open Source MANO (OSM)"[cite: 4]
    if ask_user "Do you want to download and run the OSM standalone installer now?" "N"; then[cite: 4]
        log_info "Downloading OSM installer..."
        wget https://osm-download.etsi.org/ftp/osm-14.0-fourteen/install_osm.sh -O install_osm.sh[cite: 4]
        chmod +x install_osm.sh
        ./install_osm.sh || log_warn "OSM installer completed with warnings."[cite: 4]
    else
        log_info "Skipping OSM installation."[cite: 4]
    fi
}

# --- Phase 7: Setup Python Environment & Proto compilation ---
setup_sdn_python_client() {
    log_info "Phase 7: Provisioning Python virtual environment & API Clients..."[cite: 4]
    local base_dir="."  

    sudo apt-get install -y python3-venv python3-pip python3-flask[cite: 4]
    sudo python3 -m venv /opt/sdn-venv[cite: 4]
    sudo /opt/sdn-venv/bin/pip install --upgrade pip grpcio grpcio-tools grpcio-reflection ncclient xmltodict flask requests[cite: 4]

    mkdir -p "$base_dir/proto"[cite: 4]
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
message GetCrossConnectRequest { string service_id = 1; string sb_target = 2; }
message DeleteCrossConnectRequest { string service_id = 1; string sb_target = 2; }
message CrossConnectResponse {
  string status = 1; string message = 2; string service_id = 3;
  string target_node_ip = 4; int32 ingress_port = 5; int32 egress_port = 6; string admin_state = 7;
}
EOF

    /opt/sdn-venv/bin/python -m grpc_tools.protoc -I"$base_dir/proto" \
        --python_out="$base_dir/proto" --grpc_python_out="$base_dir/proto" \
        "$base_dir/proto/quantum_gnoi_switching.proto"[cite: 4]
    touch "$base_dir/proto/__init__.py"[cite: 4]
}

# --- Phase 8: Deploy Real Cloud-Native µONOS to Kubernetes ---
deploy_cloud_native_uonos() {
    log_info "Phase 8: Deploying Cloud-Native µONOS microservices to Kubernetes..."
    
    export KUBECONFIG=${KUBECONFIG:-~/.kube/config}

    log_info "Creating Kubernetes namespace: micro-onos..."
    kubectl create namespace micro-onos --dry-run=client -o yaml | kubectl apply -f -

    log_info "Deploying Atomix Runtime (Consensus Engine)..."
    helm upgrade --install atomix-runtime onosproject/atomix-runtime -n micro-onos 

    log_info "Deploying µONOS Topology (onos-topo)..."
    helm upgrade --install onos-topo onosproject/onos-topo -n micro-onos 

    log_info "Deploying µONOS Config (onos-config)..."
    helm upgrade --install onos-config onosproject/onos-config -n micro-onos 

    log_success "Real µONOS microservices successfully scheduled in Kubernetes."
}

# --- Main Execution ---
echo -e "${CYAN}===========================================================${NC}"[cite: 4]
echo -e "${CYAN}   Quantum-SDN Switching Architecture Environment Setup    ${NC}"[cite: 4]
echo -e "${CYAN}===========================================================${NC}"[cite: 4]

stop_unattended_upgrades
create_repo_structure
install_sys_deps
install_docker
install_kubectl_and_helm
ensure_kubernetes_cluster
setup_persistent_sdn_networking
setup_helm_repos
install_grpc_tools
install_osm_installer
setup_sdn_python_client
deploy_cloud_native_uonos

echo -e "${GREEN}====================================================${NC}"[cite: 4]
echo -e "${GREEN} Setup Complete!${NC}"[cite: 4]
echo -e "To view your µONOS Kubernetes pods, run:"
echo -e "  kubectl get pods -n micro-onos"
echo -e "${GREEN}====================================================${NC}"[cite: 4]
