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

wait_for_apt_lock() {
    log_info "Checking for dpkg/apt locks..."
    while sudo fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
          sudo fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
          sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        log_info "Waiting for background updates to release the apt lock..."
        sleep 5
    done
}

stop_unattended_upgrades() {
    log_info "Phase 0: Disabling unattended-upgrades to prevent APT lock conflicts..."
    sudo systemctl stop unattended-upgrades 2>/dev/null || true
    sudo systemctl disable unattended-upgrades 2>/dev/null || true
    log_success "unattended-upgrades stopped and disabled."
}

ensure_sufficient_memory() {
    log_info "Phase 0.5: Checking system RAM and configuring Swap..."
    
    local total_ram_mb
    total_ram_mb=$(free -m | awk '/^Mem:/{print $2}')
    local min_ram_mb=8000 # 8GB threshold
    
    log_info "Detected physical RAM: ${total_ram_mb} MB"
    
    if [ "$total_ram_mb" -lt "$min_ram_mb" ]; then
        log_warn "System RAM (${total_ram_mb}MB) is below recommended ${min_ram_mb}MB."
        
        local total_swap_mb
        total_swap_mb=$(free -m | awk '/^Swap:/{print $2}')
        
        if [ "$total_swap_mb" -ge 4000 ]; then
            log_success "Sufficient Swap space (${total_swap_mb} MB) is already configured."
        else
            log_info "Configuring an 8GB swap file to prevent OOM errors..."
            
            sudo swapoff -a 2>/dev/null || true
            
            if ! sudo fallocate -l 8G /swapfile 2>/dev/null; then
                log_info "fallocate failed, using dd to allocate swap..."
                sudo dd if=/dev/zero of=/swapfile bs=1M count=8192 status=progress
            fi
            
            sudo chmod 600 /swapfile
            sudo mkswap /swapfile
            sudo swapon /swapfile
            
            if ! grep -q '/swapfile' /etc/fstab; then
                echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
            fi
            
            log_success "8GB swap file successfully enabled and configured."
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
    local deps="curl git wget jq build-essential python3-pip python3-venv python3-flask gpg psmisc golang-go"
    local to_install=""

    for pkg in $deps; do
        if ! dpkg -l | grep -qw "$pkg"; then
            to_install="$to_install $pkg"
        fi
    done

    if [ -n "$to_install" ]; then
        log_info "Installing missing packages:$to_install"
        wait_for_apt_lock
        sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y $to_install
        log_success "System dependencies installed."
    else
        log_success "All basic system dependencies are already installed."
    fi

    if ! command -v juju >/dev/null 2>&1; then
        log_info "Installing Juju CLI..."
        sudo snap install juju --classic
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

    # Get the current username (works with sudo)
    CURRENT_USER=$(whoami)
    # If running with sudo, get the original user
    if [ -n "$SUDO_USER" ]; then
        CURRENT_USER="$SUDO_USER"
    fi
    
    echo "Adding user $CURRENT_USER to docker group..."
    
    # Add user to docker group
    sudo usermod -aG docker "$CURRENT_USER"
    
    # Check if it was successful
    if [ $? -eq 0 ]; then
        echo "User $CURRENT_USER added to docker group successfully!"
        
        # Inform user about restart options
        echo ""
        echo "To apply the changes, you have several options:"
        echo "1. Log out and log back in (recommended)"
        echo "2. Run: newgrp docker"
        echo "3. Run: exec su -l $CURRENT_USER"
        echo ""
        echo "The script will now continue with newgrp docker..."
        
        sg docker "$0"
        
        # Note: exec replaces the current shell, so anything after this won't run
        # If you want to continue the script after, use this instead:
        # newgrp docker <<EOF
        #   # Your docker commands here
        #   docker ps
        # EOF
    else
        echo "Failed to add user to docker group"
        exit 1
    fi
}

install_kubectl_and_helm() {
    if ! command -v kubectl >/dev/null 2>&1; then
        log_info "Configuring Kubernetes APT keyring non-interactively..."
        sudo mkdir -p -m 755 /etc/apt/keyrings
        curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key | \
            sudo gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
        echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /" | \
            sudo tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

        log_info "Installing kubectl..."
        wait_for_apt_lock
        sudo DEBIAN_FRONTEND=noninteractive apt-get update -y && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y kubectl
    else
        log_success "kubectl is already installed."
    fi

    if ! command -v helm >/dev/null 2>&1; then
        log_info "Installing Helm..."
        curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 && chmod 700 get_helm.sh && ./get_helm.sh
        rm -f get_helm.sh
    else
        log_success "Helm is already installed."
    fi
}

ensure_kubernetes_cluster() {
    log_info "Verifying active Kubernetes cluster for µONOS and OSM deployment..."
    
    export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}
    
    sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0 2>/dev/null || true
    echo "kernel.apparmor_restrict_unprivileged_userns=0" | sudo tee /etc/sysctl.d/99-juju.conf >/dev/null
    
    if kubectl cluster-info >/dev/null 2>&1; then
        log_success "Kubernetes cluster is already running and accessible. Skipping K3s re-installation."
        return 0
    fi

    log_info "No active cluster detected. Enforcing K3s v1.26.15 configuration with active ServiceLB..."
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
    if [ -f "/etc/sysctl.d/99-sdn-uonos.conf" ] && dpkg -l | grep -qw iptables-persistent; then
        log_success "Persistent SDN networking is already configured."
        return 0
    fi
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
    
    wait_for_apt_lock
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent netfilter-persistent

    sudo netfilter-persistent save
}

setup_helm_repos() {
    if helm repo list 2>/dev/null | grep -q "atomix" && \
       helm repo list 2>/dev/null | grep -q "onosproject" && \
       helm repo list 2>/dev/null | grep -q "towards5gs"; then
        log_success "Helm repositories are already configured."
        return 0
    fi
    log_info "Phase 4: Setting up Helm repositories for µONOS and Open5GS..."
    
    helm repo add atomix https://atomix.github.io/charts.atomix.io || log_warn "Failed to add atomix repository."
    helm repo add onosproject https://charts.onosproject.org || log_warn "Failed to add onosproject repository."
    helm repo add towards5gs https://raw.githubusercontent.com/Orange-OpenSource/towards5gs-helm/main/repo/ || \
        helm repo add towards5gs https://cdn.jsdelivr.net/gh/Orange-OpenSource/towards5gs-helm@main/repo/ || log_warn "Failed to add towards5gs repository."
    
    helm repo update
}

install_grpc_tools() {
    log_info "Phase 5: Checking gRPC/protobuf tools and gnmic for gNMI..."
    if ! command -v protoc >/dev/null 2>&1; then
        wait_for_apt_lock
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y protobuf-compiler
    fi
    if ! command -v grpcurl >/dev/null 2>&1; then
        wget https://github.com/fullstorydev/grpcurl/releases/download/v1.8.7/grpcurl_1.8.7_linux_x86_64.tar.gz
        tar -xvf grpcurl_1.8.7_linux_x86_64.tar.gz
        sudo mv grpcurl /usr/local/bin/
        rm -f grpcurl_1.8.7_linux_x86_64.tar.gz LICENSE
    fi
    if ! command -v gnmic >/dev/null 2>&1; then
        log_info "Installing gnmic CLI tool..."
        bash -c "$(curl -sL https://get-gnmic.openconfig.net)"
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

    log_info "Purging stale Juju client cache, orphaned controllers, and leftover namespaces..."
    juju destroy-model osm -y --destroy-storage --force 2>/dev/null || true
    rm -rf ~/.local/share/juju ~/.cache/juju 2>/dev/null || true
    kubectl delete namespace controller-osm-vca --force --grace-period=0 2>/dev/null || true
    kubectl delete namespace osm --force --grace-period=0 2>/dev/null || true

    while kubectl get namespace osm >/dev/null 2>&1; do
        log_info "Waiting for leftover 'osm' namespace to terminate..."
        sleep 2
    done
    while kubectl get namespace controller-osm-vca >/dev/null 2>&1; do
        log_info "Waiting for leftover 'controller-osm-vca' namespace to terminate..."
        sleep 2
    done

    log_info "Configuring CoreDNS upstream servers and kernel IP forwarding..."
    sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    kubectl get configmap coredns -n kube-system -o json 2>/dev/null | sed 's/forward . \/etc\/resolv.conf/forward . 8.8.8.8 1.1.1.1/' | kubectl apply -f - >/dev/null 2>&1 || true
    kubectl rollout restart deployment coredns -n kube-system >/dev/null 2>&1 || true

    log_info "Ensuring K3s local storage class is fully initialized..."
    kubectl rollout status deployment/local-path-provisioner -n kube-system --timeout=60s || true

    log_info "Registering local K3s cluster with Juju..."
    juju add-k8s k8s-cloud --client || true

    log_info "Launching background surgical fix for API Server..."
    (
        while ! kubectl get pod controller-0 -n controller-osm-vca 2>/dev/null | grep -qE "1/2|2/2"; do
            sleep 1
        done

        while ! kubectl exec -n controller-osm-vca controller-0 -c api-server -- stat /var/lib/juju/template-ca.crt >/dev/null 2>&1; do
            sleep 1
        done

        kubectl exec -n controller-osm-vca controller-0 -c api-server -- sh -c 'cp /var/lib/juju/template-ca.crt /var/lib/juju/ca.crt && cp /var/lib/juju/template-server.pem /var/lib/juju/server.pem && kill 1' 2>/dev/null || true
    ) &
    CERT_SYNC_PID=$!

    # Standardize on ubuntu@22.04 for Juju 3 + K8s Charmhub compatibility
    JUJU_BASE="ubuntu@22.04"

    log_info "Bootstrapping Juju Controller with base ${JUJU_BASE}..."
    juju bootstrap k8s-cloud osm-vca \
        --config default-base=$JUJU_BASE \
        --model-default default-base=$JUJU_BASE || true

    kill $CERT_SYNC_PID 2>/dev/null || true
    
    log_info "Adding 'osm' model on k8s-cloud with forced default base..."
    juju add-model osm k8s-cloud --config default-base=$JUJU_BASE

    log_info "Deploying Charmed OSM microservices with charm-specific bases..."

    # Infrastructure Services
    juju deploy zookeeper-k8s --channel 3/stable --base ubuntu@22.04 --trust
    juju deploy ch:kafka-k8s --channel latest/stable --base ubuntu@20.04 --trust
    juju deploy mongodb-k8s --channel 6/stable --base ubuntu@22.04 --trust
    juju deploy charmed-osm-mariadb-k8s mariadb-k8s --channel latest/stable --base ubuntu@20.04 --trust
    juju deploy osm-prometheus prometheus-k8s --channel 14.0/stable --base ubuntu@20.04 --trust

    # OSM Core Services
    juju deploy osm-keystone keystone-k8s --channel 10.0/stable --base ubuntu@22.04 --resource keystone-image=opensourcemano/keystone:10.0.3 --trust
    juju deploy osm-nbi nbi-k8s --channel 14.0/stable --base ubuntu@22.04 --trust
    juju deploy osm-lcm lcm-k8s --channel 14.0/stable --base ubuntu@22.04 --trust
    juju deploy osm-ro ro-k8s --channel 14.0/stable --base ubuntu@22.04 --trust
    juju deploy osm-mon mon-k8s --channel 14.0/stable --base ubuntu@22.04 --trust
    juju deploy osm-pol pol-k8s --channel 14.0/stable --base ubuntu@22.04 --trust
    juju deploy osm-ng-ui ng-ui-k8s --channel 14.0/stable --base ubuntu@22.04 --trust

    # Ingress Controller
    juju deploy nginx-ingress-integrator nbi-ingress --channel latest/stable --base ubuntu@22.04 --trust

    log_info "Integrating OSM microservices..."
    until ! juju status | grep -q "allocating"; do
        echo "Waiting for Juju allocation to finish...(to check: juju status -m osm --watch 5s)"
        sleep 30
    done
    
    # Core Infrastructure Relations
    juju integrate zookeeper-k8s:zookeeper kafka-k8s:zookeeper

    # MariaDB Relations
    juju integrate mariadb-k8s:mysql keystone-k8s:db
    juju integrate mariadb-k8s:mysql pol-k8s:mysql

    # MongoDB Relations
    juju integrate mongodb-k8s:database nbi-k8s:mongodb
    juju integrate mongodb-k8s:database lcm-k8s:mongodb
    juju integrate mongodb-k8s:database ro-k8s:mongodb
    juju integrate mongodb-k8s:database mon-k8s:mongodb
    juju integrate mongodb-k8s:database pol-k8s:mongodb

    # Kafka Relations
    juju integrate kafka-k8s:kafka nbi-k8s:kafka
    juju integrate kafka-k8s:kafka lcm-k8s:kafka
    juju integrate kafka-k8s:kafka mon-k8s:kafka

    # Prometheus Relations
    juju integrate prometheus-k8s:prometheus mon-k8s:prometheus
    juju integrate prometheus-k8s:prometheus nbi-k8s:prometheus

    # Keystone & Microservice Inter-relations
    juju integrate keystone-k8s:keystone nbi-k8s:keystone
    juju integrate keystone-k8s:keystone mon-k8s:keystone
    juju integrate ro-k8s:ro lcm-k8s:ro
    juju integrate nbi-k8s:nbi ng-ui-k8s:nbi
    juju integrate nbi-k8s:ingress nbi-ingress:ingress

    log_success "OSM deployment and integrations initiated successfully."
}

setup_sdn_python_client() {
    local base_dir="."  
    if [ -d "/opt/sdn-venv" ] && [ -f "$base_dir/proto/__init__.py" ]; then
         log_success "Python environment and Protobuf stubs are already initialized."
         return 0
    fi
    log_info "Phase 7: Provisioning Python environment and compiling Protobuf stubs..."

    wait_for_apt_lock
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y python3-venv python3-pip python3-flask
    
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
    if command -v docker >/dev/null 2>&1 && docker images --format "{{.Repository}}:{{.Tag}}" | grep -q "onosproject/controller-quantum-switching:1.0.0-controller-quantum-switching-1.0.0"; then
        log_success "µONOS YANG Model Plugin image is already compiled."
        return 0
    fi
    log_info "Phase 7.5: Compiling µONOS YANG Model Plugins..."
    
    local yang_target="./orchestration/yang-models/controller-quantum-switching.yang"
    local plugin_dir="./sdn-controller/northbound-interfaces/model-plugin"
    local plugin_yang_dir="${plugin_dir}/yang"
    
    mkdir -p "$plugin_yang_dir"
    
    if [ -f "$yang_target" ]; then
        log_info "Copying tracked repository YANG model to plugin build workspace..."
        cp "$yang_target" "$plugin_yang_dir/controller-quantum-switching.yang"
    else
        log_warn "YANG model $yang_target not found! Creating fallback skeleton YANG model..."
        cat <<'EOF' > "$plugin_yang_dir/controller-quantum-switching.yang"
module controller-quantum-switching {
    yang-version 1.1;
    namespace "urn:custom:params:xml:ns:yang:controller-quantum-switching";
    prefix qswitch;

    organization "Custom";
    contact "SDN Architecture Team <sdn@example.com>";
    description "Quantum Switching Model";

    revision 2026-01-01 {
        description "Initial revision.";
        reference "RFC 8407 Compliance";
    }

    container switching {
        description "Top-level container for switching configurations.";
        leaf state {
            type enumeration {
                enum enabled {
                    description "Enable switching.";
                }
                enum disabled {
                    description "Disable switching.";
                }
            }
            default enabled;
            description "Switching operational state.";
        }
    }
}
EOF
    fi

    log_info "Sanitizing YANG model for pyang RFC 8407 compliance..."
    python3 - << 'EOF'
import re

yang_file = "./sdn-controller/northbound-interfaces/model-plugin/yang/controller-quantum-switching.yang"
with open(yang_file, "r") as f:
    content = f.read()

if "contact" not in content:
    content = re.sub(r'(organization\s+[^;]+;)', r'\1\n    contact "SDN Architecture Team <sdn@example.com>";', content)

if "reference" not in content:
    content = re.sub(r'(revision\s+[0-9\-]+\s*\{[^}]*description\s+[^;]+;)', r'\1\n        reference "RFC 8407 Compliance";', content)

content = re.sub(r'enum\s+ENABLED\s*;', 'enum enabled {\n            description "Enabled state.";\n        }', content)
content = re.sub(r'enum\s+DISABLED\s*;', 'enum disabled {\n            description "Disabled state.";\n        }', content)
content = re.sub(r'enum\s+ENABLED\s*\{', 'enum enabled {\n            description "Enabled state.";', content)
content = re.sub(r'enum\s+DISABLED\s*\{', 'enum disabled {\n            description "Disabled state.";', content)

with open(yang_file, "w") as f:
    f.write(content)
EOF

    echo "1.0.0" > "$plugin_dir/VERSION"

    cat <<EOF > "$plugin_dir/metadata.yaml"
name: controller-quantum-switching
version: 1.0.0
contactName: "SDN Architecture Team"
licenseName: "Apache-2.0"
artifactName: controller-quantum-switching
goPackage: github.com/onosproject/controller-quantum-switching
modules:
  - name: controller-quantum-switching
    organization: custom
    revision: "2026-01-01"
    file: controller-quantum-switching.yang
EOF

    local plugin_dir="./sdn-controller/northbound-interfaces/model-plugin"

    log_info "Executing onosproject/model-compiler..."
    docker run --rm -v "$(pwd)/$plugin_dir:/config-model" onosproject/model-compiler:latest

    sudo chown -R $USER:$USER "$plugin_dir"

    log_info "Building the resulting Model Plugin Docker Image..."
    if [ -f "$plugin_dir/Makefile" ]; then
        (cd "$plugin_dir" && make image) || log_error "Failed to build the model plugin image."
        
        if command -v docker >/dev/null 2>&1 && command -v k3s >/dev/null 2>&1; then
            log_info "Importing model plugin image into K3s containerd..."
            docker save onosproject/controller-quantum-switching:1.0.0-controller-quantum-switching-1.0.0 2>/dev/null | sudo k3s ctr images import - || true
        fi
    else
        log_warn "Makefile not found in $plugin_dir. Model compilation may have failed."
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

    log_info "Purging stale Helm releases..."
    helm uninstall atomix-controller atomix-raft-storage onos-operator -n micro-onos 2>/dev/null || true
    helm uninstall atomix-controller atomix-raft-storage onos-operator -n kube-system 2>/dev/null || true
    helm uninstall onos-topo onos-config -n micro-onos 2>/dev/null || true

    log_info "Removing legacy Atomix CRDs..."
    kubectl delete crd storageprofiles.atomix.io raftclusters.raft.atomix.io raftstores.raft.atomix.io --ignore-not-found 2>/dev/null || true

    log_info "Applying Atomix stub CRDs directly..."
    kubectl apply -f - <<EOF
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: raftclusters.raft.atomix.io
spec:
  group: raft.atomix.io
  names:
    kind: RaftCluster
    listKind: RaftClusterList
    plural: raftclusters
    singular: raftcluster
  scope: Namespaced
  versions:
  - name: v2beta2
    served: true
    storage: true
    subresources:
      status: {}
    schema:
      openAPIV3Schema:
        type: object
        x-kubernetes-preserve-unknown-fields: true
  - name: v1beta3
    served: true
    storage: false
    subresources:
      status: {}
    schema:
      openAPIV3Schema:
        type: object
        x-kubernetes-preserve-unknown-fields: true
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: raftstores.raft.atomix.io
spec:
  group: raft.atomix.io
  names:
    kind: RaftStore
    listKind: RaftStoreList
    plural: raftstores
    singular: raftstore
  scope: Namespaced
  versions:
  - name: v2beta2
    served: true
    storage: true
    subresources:
      status: {}
    schema:
      openAPIV3Schema:
        type: object
        x-kubernetes-preserve-unknown-fields: true
  - name: v1beta3
    served: true
    storage: false
    subresources:
      status: {}
    schema:
      openAPIV3Schema:
        type: object
        x-kubernetes-preserve-unknown-fields: true
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: raftprotocols.raft.atomix.io
spec:
  group: raft.atomix.io
  names:
    kind: RaftProtocol
    listKind: RaftProtocolList
    plural: raftprotocols
    singular: raftprotocol
  scope: Namespaced
  versions:
  - name: v2beta2
    served: true
    storage: true
    subresources:
      status: {}
    schema:
      openAPIV3Schema:
        type: object
        x-kubernetes-preserve-unknown-fields: true
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: raftgroups.raft.atomix.io
spec:
  group: raft.atomix.io
  names:
    kind: RaftGroup
    listKind: RaftGroupList
    plural: raftgroups
    singular: raftgroup
  scope: Namespaced
  versions:
  - name: v2beta2
    served: true
    storage: true
    subresources:
      status: {}
    schema:
      openAPIV3Schema:
        type: object
        x-kubernetes-preserve-unknown-fields: true
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: raftmembers.raft.atomix.io
spec:
  group: raft.atomix.io
  names:
    kind: RaftMember
    listKind: RaftMemberList
    plural: raftmembers
    singular: raftmember
  scope: Namespaced
  versions:
  - name: v2beta2
    served: true
    storage: true
    subresources:
      status: {}
    schema:
      openAPIV3Schema:
        type: object
        x-kubernetes-preserve-unknown-fields: true
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: storageprofiles.atomix.io
spec:
  group: atomix.io
  names:
    kind: StorageProfile
    listKind: StorageProfileList
    plural: storageprofiles
    singular: storageprofile
  scope: Namespaced
  versions:
  - name: v3beta4
    served: true
    storage: true
    subresources:
      status: {}
    schema:
      openAPIV3Schema:
        type: object
        x-kubernetes-preserve-unknown-fields: true
  - name: v2beta1
    served: true
    storage: false
    subresources:
      status: {}
    schema:
      openAPIV3Schema:
        type: object
        x-kubernetes-preserve-unknown-fields: true
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: multiraftprotocols.storage.atomix.io
spec:
  group: storage.atomix.io
  names:
    kind: MultiRaftProtocol
    listKind: MultiRaftProtocolList
    plural: multiraftprotocols
    singular: multiraftprotocol
  scope: Namespaced
  versions:
  - name: v2beta1
    served: true
    storage: true
    subresources:
      status: {}
    schema:
      openAPIV3Schema:
        type: object
        x-kubernetes-preserve-unknown-fields: true
  - name: v2beta2
    served: true
    storage: false
    subresources:
      status: {}
    schema:
      openAPIV3Schema:
        type: object
        x-kubernetes-preserve-unknown-fields: true
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: databases.cloud.atomix.io
spec:
  group: cloud.atomix.io
  names:
    kind: Database
    listKind: DatabaseList
    plural: databases
    singular: database
  scope: Namespaced
  versions:
  - name: v1beta3
    served: true
    storage: true
    subresources:
      status: {}
    schema:
      openAPIV3Schema:
        type: object
        x-kubernetes-preserve-unknown-fields: true
  - name: v1beta2
    served: true
    storage: false
    subresources:
      status: {}
    schema:
      openAPIV3Schema:
        type: object
        x-kubernetes-preserve-unknown-fields: true
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: partitionsets.cloud.atomix.io
spec:
  group: cloud.atomix.io
  names:
    kind: PartitionSet
    listKind: PartitionSetList
    plural: partitionsets
    singular: partitionset
  scope: Namespaced
  versions:
  - name: v1beta3
    served: true
    storage: true
    subresources:
      status: {}
    schema:
      openAPIV3Schema:
        type: object
        x-kubernetes-preserve-unknown-fields: true
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: partitions.cloud.atomix.io
spec:
  group: cloud.atomix.io
  names:
    kind: Partition
    listKind: PartitionList
    plural: partitions
    singular: partition
  scope: Namespaced
  versions:
  - name: v1beta3
    served: true
    storage: true
    subresources:
      status: {}
    schema:
      openAPIV3Schema:
        type: object
        x-kubernetes-preserve-unknown-fields: true
---
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: members.cloud.atomix.io
spec:
  group: cloud.atomix.io
  names:
    kind: Member
    listKind: MemberList
    plural: members
    singular: member
  scope: Namespaced
  versions:
  - name: v1beta3
    served: true
    storage: true
    subresources:
      status: {}
    schema:
      openAPIV3Schema:
        type: object
        x-kubernetes-preserve-unknown-fields: true
EOF

    log_info "Waiting for CRDs to register..."
    kubectl wait --for=condition=established \
    crd/raftclusters.raft.atomix.io \
    crd/raftstores.raft.atomix.io \
    crd/storageprofiles.atomix.io \
    crd/multiraftprotocols.storage.atomix.io \
    crd/databases.cloud.atomix.io \
    crd/partitionsets.cloud.atomix.io \
    crd/partitions.cloud.atomix.io \
    crd/members.cloud.atomix.io \
    --timeout=30s 2>/dev/null || true

    log_info "Installing v1beta3-compatible Atomix controllers and onos controllers..."
    helm install atomix-controller atomix/atomix-controller -n kube-system --version 0.6.9
    helm install atomix-raft-storage atomix/atomix-raft-storage -n kube-system --version 0.1.8
    helm install onos-topo onos/onos-topo -n micro-onos
    helm install onos-config onos/onos-config -n micro-onos

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
echo -e "To view your µONOS Kubernetes pods and juju services, run:"
echo -e "  kubectl get pods -n micro-onos"
echo -e "  juju status --watch 5s"
echo -e "${GREEN}====================================================${NC}"
