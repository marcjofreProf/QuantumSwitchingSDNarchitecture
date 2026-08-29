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
    log_info "Phase 0: Disabling unattended-upgrades to prevent APT lock conflicts..."
    sudo systemctl stop unattended-upgrades 2>/dev/null || true
    sudo systemctl disable unattended-upgrades 2>/dev/null || true
    log_success "unattended-upgrades stopped and disabled."
}

# --- Phase 1: Repository Scaffolding ---
create_repo_structure() {
    log_info "Phase 1: Ensuring repository directory structure..."
    local base_dir="."

    mkdir -p "$base_dir"/.github/workflows \
             "$base_dir"/docs/architecture \
             "$base_dir"/docs/api \
             "$base_dir"/deploy/vm-provisioning \
             "$base_dir"/deploy/k8s-cluster \
             "$base_dir"/sdn-controller/apps \
             "$base_dir"/sdn-controller/southbound-plugins \
             "$base_dir"/sdn-controller/northbound-interfaces/model-plugin/yang \
             "$base_dir"/sdn-controller/northbound-interfaces/restconf-gateway \
             "$base_dir"/orchestration/osm-packages \
             "$base_dir"/orchestration/yang-models \
             "$base_dir"/workloads/open5gs \
             "$base_dir"/hardware-agents/gnoi-targets \
             "$base_dir"/hardware-agents/netconf-servers \
             "$base_dir"/hardware-agents/restconf-servers \
             "$base_dir"/hardware-agents/switch-drivers \
             "$base_dir"/tests/latency-benchmarks \
             "$base_dir"/tests/e2e-path-provisioning \
             "$base_dir"/proto

    log_success "Repository structure verified."
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

# --- Phase 3: Docker, Kubernetes Tools & Local K8s Cluster ---
install_docker() {
    log_info "Checking Docker..."
    if command -v docker >/dev/null 2>&1; then
        log_success "Docker is already installed ($(docker --version))."
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
    log_info "Configuring Kubernetes APT keyring non-interactively..."
    sudo mkdir -p -m 755 /etc/apt/keyrings
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | \
        sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /" | \
        sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

    if ! command -v kubectl >/dev/null 2>&1; then
        log_info "Installing kubectl..."
        sudo DEBIAN_FRONTEND=noninteractive apt-get update -y && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y kubectl
    fi

    if ! command -v helm >/dev/null 2>&1; then
        log_info "Installing Helm..."
        curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 && chmod 700 get_helm.sh && ./get_helm.sh
        rm -f get_helm.sh
    fi
}

ensure_kubernetes_cluster() {
    log_info "Verifying active Kubernetes cluster for µONOS deployment..."
    if ! sudo kubectl cluster-info >/dev/null 2>&1; then
        log_warn "No active Kubernetes cluster found. Deploying standalone K3s..."
        
        if [ -f /usr/local/bin/k3s-uninstall.sh ]; then
            sudo /usr/local/bin/k3s-uninstall.sh >/dev/null 2>&1 || true
        fi
        
        # Install standard K3s (containerd) without Traefik to avoid port conflicts
        curl -sfL https://get.k3s.io | sh -s - server --disable traefik --disable servicelb
        
        # Wait a moment for the configuration file to be generated
        sleep 5
        
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
    log_info "Phase 3.5: Applying persistent iptables and kernel network configurations..."
    echo "br_netfilter" | sudo tee /etc/modules-load.d/sdn-uonos.conf >/dev/null
    sudo modprobe br_netfilter

    sudo sed -i '/net.core.bpf_jit_limit/d' /etc/sysctl.d/*.conf /etc/sysctl.conf 2>/dev/null || true

    cat <<EOF | sudo tee /etc/sysctl.d/99-sdn-uonos.conf >/dev/null
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
EOF
    sudo sysctl -p /etc/sysctl.d/99-sdn-uonos.conf >/dev/null
    sudo iptables -P FORWARD ACCEPT

    echo iptables-persistent iptables-persistent/enable-ipv4 boolean true | sudo debconf-set-selections
    echo iptables-persistent iptables-persistent/enable-ipv6 boolean true | sudo debconf-set-selections
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent netfilter-persistent

    sudo netfilter-persistent save
}

# --- Phase 4: SDN Controller (µONOS) & Open5GS Repos ---
setup_helm_repos() {
    log_info "Phase 4: Setting up Helm repositories for µONOS (onosproject) and Open5GS (towards5gs)..."
    helm repo add onosproject https://charts.onosproject.org || log_warn "Failed to add onosproject repository."
    helm repo add towards5gs https://raw.githubusercontent.com/Orange-OpenSource/towards5gs-helm/main/repo/ || \
        helm repo add towards5gs https://cdn.jsdelivr.net/gh/Orange-OpenSource/towards5gs-helm@main/repo/
    helm repo update
}

# --- Phase 5: gRPC, gNOI & gNMI Tooling ---
install_grpc_tools() {
    log_info "Phase 5: Checking gRPC/protobuf tools and gnmic for gNMI..."
    if ! command -v protoc >/dev/null 2>&1; then
        sudo apt-get install -y protobuf-compiler
    fi
    if ! command -v grpcurl >/dev/null 2>&1; then
        wget https://github.com/fullstorydev/grpcurl/releases/download/v1.8.7/grpcurl_1.8.7_linux_x86_64.tar.gz
        tar -xvf grpcurl_1.8.7_linux_x86_64.tar.gz
        sudo mv grpcurl /usr/local/bin/
        rm -f grpcurl_1.8.7_linux_x86_64.tar.gz LICENSE
    fi
    if ! command -v gnmic >/dev/null 2>&1; then
        log_info "Installing gnmic CLI tool..."
        bash -c "$(curl -sLO https://gnmic.openconfig.net/install.sh && chmod +x install.sh && ./install.sh)" || \
        sudo bash -c "$(wget -qO- https://gnmic.openconfig.net/install.sh)"
        log_success "gnmic installed successfully."
    fi
}

# --- Phase 6: Orchestration (OSM) ---
install_osm_installer() {
    log_info "Phase 6: Open Source MANO (OSM)"
    if ask_user "Do you want to download and run the OSM standalone installer now?" "N"; then
        log_info "Downloading OSM installer..."
        wget https://osm-download.etsi.org/ftp/osm-14.0-fourteen/install_osm.sh -O install_osm.sh
        chmod +x install_osm.sh
        ./install_osm.sh || log_warn "OSM installer completed with warnings."
    else
        log_info "Skipping OSM installation."
    fi
}

# --- Phase 7: Setup Python Environment & Proto Compilation ---
setup_sdn_python_client() {
    log_info "Phase 7: Provisioning Python environment and compiling Protobuf stubs..."
    local base_dir="."  

    sudo apt-get install -y python3-venv python3-pip python3-flask
    sudo python3 -m venv /opt/sdn-venv
    sudo /opt/sdn-venv/bin/pip install --upgrade pip grpcio grpcio-tools grpcio-reflection ncclient xmltodict flask requests

    if [ -f "$base_dir/proto/quantum_gnoi_switching.proto" ]; then
        log_info "Compiling quantum_gnoi_switching.proto..."
        /opt/sdn-venv/bin/python -m grpc_tools.protoc -I"$base_dir/proto" \
            --python_out="$base_dir/proto" --grpc_python_out="$base_dir/proto" \
            "$base_dir/proto/quantum_gnoi_switching.proto"
        touch "$base_dir/proto/__init__.py"
    else
        log_warn "quantum_gnoi_switching.proto not found in ./proto/ directory!"
    fi

    chmod +x "$base_dir"/tests/e2e-path-provisioning/* 2>/dev/null || true
    chmod +x "$base_dir"/hardware-agents/switch-drivers/* 2>/dev/null || true
    chmod +x "$base_dir"/hardware-agents/gnoi-targets/* 2>/dev/null || true
    chmod +x "$base_dir"/hardware-agents/netconf-servers/* 2>/dev/null || true

    log_success "Python environment and Protobuf stubs initialized."
}

# --- Phase 7.5: µONOS Model Plugin Compilation ---
compile_uonos_model_plugins() {
    log_info "Phase 7.5: Compiling µONOS YANG Model Plugins..."
    
    local yang_target="./orchestration/yang-models/controller-quantum-switching.yang"
    local plugin_dir="./sdn-controller/northbound-interfaces/model-plugin"
    local plugin_yang_dir="${plugin_dir}/yang"
    
    if [ -f "$yang_target" ]; then
        log_info "Copying tracked repository YANG model to plugin build workspace..."
        cp "$yang_target" "$plugin_yang_dir/"
    else
        log_warn "YANG model $yang_target not found!"
    fi

    if [ -f "$plugin_dir/controller-quantum-switching-model.yaml" ]; then
        cp "$plugin_dir/controller-quantum-switching-model.yaml" "$plugin_dir/metadata.yaml"
    fi

    log_info "Executing onosproject/model-compiler..."
    if command -v docker >/dev/null 2>&1; then
        docker run --rm -v "$(pwd)/${plugin_dir}:/config-model" onosproject/model-compiler:latest || log_warn "Model compiler encountered an issue."
        
        log_info "Building the resulting Model Plugin Docker Image..."
        if [ -f "$plugin_dir/Makefile" ]; then
            (cd "$plugin_dir" && make image) || log_warn "Failed to build the model plugin image."
            log_success "Model Plugin image successfully compiled."
        else
            log_warn "Makefile not generated by model-compiler. Skipping image build."
        fi
    else
        log_warn "Docker not running. Skipping model compilation."
    fi
}

# --- Phase 8: Deploy Cloud-Native µONOS & RESTCONF Gateway ---
deploy_cloud_native_uonos() {
    log_info "Phase 8: Deploying µONOS microservices and RESTCONF Gateway..."
    export KUBECONFIG=${KUBECONFIG:-~/.kube/config}

    kubectl create namespace micro-onos --dry-run=client -o yaml | kubectl apply -f -

    log_info "Deploying Atomix Runtime, onos-topo, and onos-config..."
    helm upgrade --install atomix-runtime onosproject/atomix-runtime -n micro-onos 
    helm upgrade --install onos-topo onosproject/onos-topo -n micro-onos 
    helm upgrade --install onos-config onosproject/onos-config -n micro-onos 

    log_info "Building and deploying RESTCONF Gateway Container..."
    if command -v docker >/dev/null 2>&1; then
        (cd "./sdn-controller/northbound-interfaces/restconf-gateway" && docker build -t quantum-restconf-gateway:1.0.0 .)
        
        if command -v k3s >/dev/null 2>&1; then
            docker save quantum-restconf-gateway:1.0.0 | sudo k3s ctr images import -
        fi

        kubectl apply -n micro-onos -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: restconf-gateway
spec:
  replicas: 1
  selector:
    matchLabels:
      app: restconf-gateway
  template:
    metadata:
      labels:
        app: restconf-gateway
    spec:
      containers:
      - name: restconf-gateway
        image: quantum-restconf-gateway:1.0.0
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 8181
---
apiVersion: v1
kind: Service
metadata:
  name: restconf-gateway
spec:
  type: NodePort
  selector:
    app: restconf-gateway
  ports:
  - port: 8181
    targetPort: 8181
    nodePort: 30181
EOF
        log_success "RESTCONF Gateway deployed on NodePort 30181."
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
ensure_kubernetes_cluster
setup_persistent_sdn_networking
setup_helm_repos
install_grpc_tools
install_osm_installer
setup_sdn_python_client
compile_uonos_model_plugins
deploy_cloud_native_uonos

echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN} Setup Complete!${NC}"
echo -e "To view your µONOS Kubernetes pods, run:"
echo -e "  kubectl get pods -n micro-onos"
echo -e "${GREEN}====================================================${NC}"
