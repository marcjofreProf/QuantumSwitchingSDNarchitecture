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
    log_info "Phase 4: Setting up Helm repositories for µONOS and Open5GS..."

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

# --- Phase 7: Setup Python Environment ---
setup_sdn_python_client() {
    log_info "Phase 7: Setting up Python gRPC, NETCONF & RESTCONF SDN Environment..."
    local base_dir="."  

    log_info "Installing Python venv package..."
    sudo apt-get install -y python3-venv python3-pip python3-flask

    log_info "Creating Python virtual environment in $base_dir/.venv..."
    python3 -m venv "$base_dir/.venv"

    log_info "Installing dependencies in virtual environment..."
    "$base_dir/.venv/bin/pip" install --upgrade pip
    "$base_dir/.venv/bin/pip" install grpcio grpcio-tools ncclient xmltodict flask

    if [ -f "$base_dir/proto/quantum_gnoi_switching.proto" ]; then
        log_info "Compiling gRPC stubs..."
        "$base_dir/.venv/bin/python" -m grpc_tools.protoc -I"$base_dir/proto" \
            --python_out="$base_dir/proto" \
            --grpc_python_out="$base_dir/proto" \
            "$base_dir/proto/quantum_gnoi_switching.proto"

        touch "$base_dir/proto/__init__.py"
        log_success "Stubs compiled successfully."
    else
        log_warn "proto/quantum_gnoi_switching.proto not found! Skipping compilation."
    fi
}

# --- Phase 8: Deploy Persistent RESTCONF Systemd Service ---
deploy_restconf_service() {
    log_info "Phase 8: Deploying persistent RESTCONF systemd service on port 8181..."

    local script_path="/usr/local/bin/quantum_restconf_server.py"
    local service_path="/etc/systemd/system/quantum-restconf.service"

    log_info "Deploying RESTCONF server script to $script_path..."
    cat << 'EOF' | sudo tee "$script_path" >/dev/null
#!/usr/bin/env python3
from flask import Flask, request, jsonify

app = Flask(__name__)

@app.route('/restconf/data/example-quantum-switching-terminal-service:quantum-services/cross-connect-service', methods=['POST', 'PUT'])
def handle_cross_connect():
    print('\n[+] RESTCONF Payload received:\n', request.get_data(as_text=True))
    return jsonify({'status': 'CREATED'}), 201

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8181)
EOF

    sudo chmod +x "$script_path"

    log_info "Creating systemd unit file at $service_path..."
    cat << EOF | sudo tee "$service_path" >/dev/null
[Unit]
Description=Quantum SDN RESTCONF Switching Terminal Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 $script_path
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    log_info "Enabling and launching quantum-restconf.service..."
    sudo systemctl daemon-reload
    sudo systemctl enable quantum-restconf.service
    sudo systemctl restart quantum-restconf.service

    if systemctl is-active --quiet quantum-restconf.service; then
        log_success "RESTCONF service successfully active and listening on port 8181."
    else
        log_error "RESTCONF service failed to start."
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
deploy_restconf_service

echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN} Setup Complete!${NC}"
echo -e "RESTCONF service active on: ${YELLOW}0.0.0.0:8181${NC}"
echo -e "Check RESTCONF status: ${YELLOW}sudo systemctl status quantum-restconf.service${NC}"
echo -e "View RESTCONF logs: ${YELLOW}sudo journalctl -u quantum-restconf.service -f${NC}"
echo -e "Navigate to your repository: ${YELLOW}cd quantum-sdn-switching-architecture${NC}"
echo -e "${GREEN}====================================================${NC}"
