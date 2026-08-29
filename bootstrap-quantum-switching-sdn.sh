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

export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}

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

stop_unattended_upgrades() {
    log_info "Phase 0: Disabling unattended-upgrades to prevent APT lock conflicts..."
    sudo systemctl stop unattended-upgrades 2>/dev/null || true
    sudo systemctl disable unattended-upgrades 2>/dev/null || true
    log_success "unattended-upgrades stopped and disabled."
}

ensure_sufficient_memory() {
    log_info "Phase 0.5: Checking system RAM and configuring Swap..."
    
    # Extract total RAM in MB
    local total_ram_mb
    total_ram_mb=$(free -m | awk '/^Mem:/{print $2}')
    local min_ram_mb=8000 # 8GB threshold
    
    log_info "Detected physical RAM: ${total_ram_mb} MB"
    
    if [ "$total_ram_mb" -lt "$min_ram_mb" ]; then
        log_warn "System RAM (${total_ram_mb}MB) is below recommended ${min_ram_mb}MB."
        
        # Check existing active swap space in MB
        local total_swap_mb
        total_swap_mb=$(free -m | awk '/^Swap:/{print $2}')
        
        if [ "$total_swap_mb" -ge 4000 ]; then
            log_success "Sufficient Swap space (${total_swap_mb} MB) is already configured."
        else
            log_info "Configuring an 8GB swap file to prevent OOM errors during Juju/K3s bootstrap..."
            
            sudo swapoff -a 2>/dev/null || true
            
            # Allocate 8GB swap file using fallocate with a dd fallback
            if ! sudo fallocate -l 8G /swapfile 2>/dev/null; then
                log_info "fallocate failed, using dd to allocate swap..."
                sudo dd if=/dev/zero of=/swapfile bs=1M count=8192 status=progress
            fi
            
            sudo chmod 600 /swapfile
            sudo mkswap /swapfile
            sudo swapon /swapfile
            
            # Make swap persistent across reboots
            if ! grep -q '/swapfile' /etc/fstab; then
                echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
            fi
            
            log_success "8GB swap file successfully enabled and configured in /etc/fstab."
        fi
    else
        log_success "Sufficient physical RAM detected."
    fi
}

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
    log_info "Verifying active Kubernetes cluster for µONOS and OSM deployment..."
    
    export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}
    
    # Apply Ubuntu 24.04 AppArmor patch for Juju
    sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0 2>/dev/null || true
    echo "kernel.apparmor_restrict_unprivileged_userns=0" | sudo tee /etc/sysctl.d/99-juju.conf >/dev/null
    
    # Ensure K3s is pinned to v1.26.15 (OSM 14 compatible)
    log_info "Enforcing K3s v1.26.15 configuration with active ServiceLB..."
    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.26.15+k3s1 sh -s - server --disable traefik
    sleep 5
    
    mkdir -p ~/.kube
    sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
    sudo chown $(id -u):$(id -g) ~/.kube/config
    
    if ! grep -q 'KUBECONFIG' ~/.bashrc; then
        echo 'export KUBECONFIG=$HOME/.kube/config' >> ~/.bashrc
    fi
    log_success "K3s cluster configured with native LoadBalancer support."
}

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

setup_helm_repos() {
    log_info "Phase 4: Setting up Helm repositories for µONOS, Atomix, and Open5GS..."
    helm repo add onosproject https://charts.onosproject.org || log_warn "Failed to add onosproject repository."
    
    # Fallback structure to bypass the charts.atomix.io DNS lookup error
    helm repo add atomix https://charts.atomix.io || \
        helm repo add atomix https://atomix.github.io/atomix-helm || \
        helm repo add atomix https://atomix.github.io/atomix-helm-charts || \
        log_warn "Failed to add atomix repository from all known endpoints."
        
    helm repo add towards5gs https://raw.githubusercontent.com/Orange-OpenSource/towards5gs-helm/main/repo/ || \
        helm repo add towards5gs https://cdn.jsdelivr.net/gh/Orange-OpenSource/towards5gs-helm@main/repo/
    helm repo update
}

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

install_osm_installer() {
    log_info "Phase 6: Evaluating Open Source MANO (OSM) state..."

    local osm_active=false
    if kubectl get pods -n osm 2>/dev/null | grep -E 'nbi|ro|mon' | grep -q 'Running'; then
        osm_active=true
    fi

    if [ "$osm_active" = true ]; then
        log_success "OSM is already installed and operational in namespace 'osm'."
        if ! ask_user "Do you want to re-install / upgrade Open Source MANO?" "N"; then
            log_info "Skipping OSM re-installation."
            return 0
        fi
    else
        log_info "OSM is not currently active. Proceeding with deployment..."
    fi

    # --- SCORCHED EARTH K3S PURGE START ---
    log_info "Executing nuclear cleanup of K3s and Juju environments to prevent stale state loops..."

    # 1. Kill any frozen Juju processes
    sudo killall -9 juju 2>/dev/null || true

    # 2. Trigger native K3s uninstall to cleanly destroy K8s state, PVs, and networking
    if [ -f /usr/local/bin/k3s-uninstall.sh ]; then
        log_info "Uninstalling K3s completely..."
        sudo /usr/local/bin/k3s-uninstall.sh
    fi

    # 3. Wipe all remaining host storage and Juju client caches
    log_info "Wiping host storage and Juju caches..."
    sudo rm -rf /var/lib/rancher/k3s
    rm -rf ~/.local/share/juju ~/.cache/juju ~/.kube 2>/dev/null || true

    # 4. Re-install pristine K3s cluster (Pinned to v1.26.15)
    log_info "Re-installing pristine K3s v1.26.15 cluster..."
    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.26.15+k3s1 sh -s - server --disable traefik
    sleep 10
    
    mkdir -p ~/.kube
    sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
    sudo chown $(id -u):$(id -g) ~/.kube/config
    export KUBECONFIG=$HOME/.kube/config
    # --- SCORCHED EARTH K3S PURGE END ---

    # Fix cluster DNS resolution & enable host IP forwarding
    log_info "Configuring CoreDNS upstream servers and kernel IP forwarding..."
    sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    kubectl get configmap coredns -n kube-system -o json 2>/dev/null | sed 's/forward . \/etc\/resolv.conf/forward . 8.8.8.8 1.1.1.1/' | kubectl apply -f - >/dev/null 2>&1 || true
    kubectl rollout restart deployment coredns -n kube-system >/dev/null 2>&1 || true

    log_info "Ensuring K3s local storage class is fully initialized..."
    kubectl rollout status deployment/local-path-provisioner -n kube-system --timeout=60s || true

    # Background daemon: forces single primary host IP on controller-service
    (
        for i in {1..60}; do
            if kubectl get svc controller-service -n controller-osm-vca >/dev/null 2>&1; then
                EXT_IP_RAW=$(kubectl get svc controller-service -n controller-osm-vca -o jsonpath='{.spec.externalIPs[*]}' 2>/dev/null || true)
                
                if [[ "$EXT_IP_RAW" == *" "* ]] || [[ "$EXT_IP_RAW" == *","* ]] || [ -z "$EXT_IP_RAW" ]; then
                    HOST_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' | head -n1)
                    if [ -n "$HOST_IP" ]; then
                        kubectl patch svc controller-service -n controller-osm-vca --type='json' -p="[{\"op\": \"replace\", \"path\": \"/spec/externalIPs\", \"value\": [\"$HOST_IP\"]}]" >/dev/null 2>&1 || true
                    fi
                else
                    break
                fi
            fi
            sleep 2
        done
    ) &

    log_info "Downloading OSM installer..."
    wget https://osm-download.etsi.org/ftp/osm-14.0-fourteen/install_osm.sh -O install_osm.sh
    chmod +x install_osm.sh
    
    log_info "Running OSM installer targeting local cluster..."
    ./install_osm.sh -y --charmed --k8s ~/.kube/config || log_warn "OSM installer completed with warnings."
}

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

    cat <<EOF > "$plugin_dir/metadata.yaml"
name: controller-quantum-switching
version: 1.0.0
artifactName: controller-quantum-switching
goPackage: github.com/onosproject/controller-quantum-switching
EOF

    log_info "Executing onosproject/model-compiler..."
    if command -v docker >/dev/null 2>&1; then
        docker run --rm -v "$(pwd)/${plugin_dir}:/config-model" onosproject/model-compiler:latest || log_warn "Model compiler encountered an issue."
        
        log_info "Building the resulting Model Plugin Docker Image..."
        if [ -f "$plugin_dir/Makefile" ]; then
            (cd "$plugin_dir" && make image) || log_warn "Failed to build the model plugin image."
        fi
    fi
}

deploy_cloud_native_uonos() {
    log_info "Phase 8: Evaluating µONOS deployment state..."
    
    local uonos_active=false
    if kubectl get pods -n micro-onos 2>/dev/null | grep -E 'onos-topo|onos-config' | grep -q 'Running'; then
        uonos_active=true
    fi

    if [ "$uonos_active" = true ]; then
        log_success "µONOS is already installed and operational in namespace 'micro-onos'."
        if ! ask_user "Do you want to re-install / upgrade the µONOS deployment?" "N"; then
            log_info "Skipping µONOS re-installation."
            return 0
        fi
    else
        log_info "µONOS is not currently operational. Proceeding with deployment..."
    fi

    kubectl create namespace micro-onos --dry-run=client -o yaml | kubectl apply -f -

    log_info "Deploying Atomix Controllers..."
    helm upgrade --install atomix-controller atomix/atomix-controller -n micro-onos --wait
    
    log_info "Extracting and manually applying Atomix Raft CRDs..."
    helm pull atomix/atomix-raft-storage --untar 2>/dev/null || true
    if [ -d "atomix-raft-storage/crds" ]; then
        kubectl apply -f atomix-raft-storage/crds/ 2>/dev/null || true
        rm -rf atomix-raft-storage
    fi
    
    helm upgrade --install atomix-raft-storage atomix/atomix-raft-storage -n micro-onos --wait
    
    log_info "Waiting for Kubernetes to register Atomix CRDs..."
    local crds=("raftclusters.raft.atomix.io" "raftstores.raft.atomix.io" "storageprofiles.atomix.io")
    for crd in "${crds[@]}"; do
        local retries=15
        while ! kubectl get crd "$crd" >/dev/null 2>&1; do
            sleep 2
            retries=$((retries - 1))
            if [ $retries -le 0 ]; then break; fi
        done
        kubectl wait --for=condition=established crd/"$crd" --timeout=60s || true
    done
    
    log_info "Deploying ONOS Topology and Config..."
    helm upgrade --install onos-topo onosproject/onos-topo -n micro-onos 
    helm upgrade --install onos-config onosproject/onos-config -n micro-onos

    log_info "Building and deploying RESTCONF Gateway Container..."
    if command -v docker >/dev/null 2>&1; then
        (cd "./sdn-controller/northbound-interfaces/restconf-gateway" && docker build -t quantum-restconf-gateway:1.0.0 .) || log_warn "Skipped building Gateway image."
        
        if command -v k3s >/dev/null 2>&1; then
            docker save quantum-restconf-gateway:1.0.0 2>/dev/null | sudo k3s ctr images import - || true
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
ensure_sufficient_memory
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
