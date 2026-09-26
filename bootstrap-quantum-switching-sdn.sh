#!/bin/bash
# ./bootstrap-quantum-switching-sdn.sh
# ---------------------------------------------------------------------------
# Quantum-SDN Switching Architecture Bootstrap Script (Cloud-Native µONOS)
# ---------------------------------------------------------------------------

set -e # Exit immediately if a command exits with a non-zero status
trap 'echo "[!] bootstrap exited at line $LINENO (status $?)" >&2' ERR

# --- Colors for Output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/config}

# Cache sudo credentials up front so the script doesn't prompt repeatedly
sudo -v

log_info() { echo -e "${CYAN}[INFO] $1${NC}"; }
log_success() { echo -e "${GREEN}[SUCCESS] $1${NC}"; }
log_warn() { echo -e "${YELLOW}[WARNING] $1${NC}"; }
log_error() { echo -e "${RED}[ERROR] $1${NC}"; exit 1; }

# Remove any stale gnmic config from previous runs. Older versions of this
# script wrote ./.gnmic.yaml into the repo root, which conflicts with the
# --insecure flag used when talking to plaintext gNMI targets like the
# BeagleBone. The canonical gnmic config now lives at /etc/gnmic/gnmic.yaml.
rm -f ./.gnmic.yaml 2>/dev/null || true

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
    log_info "Phase 0: Tuning kernel file watch limits & disabling unattended-upgrades..."
    
    cat <<EOF | sudo tee /etc/sysctl.d/99-inotify-limits.conf >/dev/null
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 8192
fs.file-max = 2097152
EOF
    sudo sysctl -p /etc/sysctl.d/99-inotify-limits.conf >/dev/null

    sudo systemctl stop unattended-upgrades 2>/dev/null || true
    sudo systemctl disable unattended-upgrades 2>/dev/null || true
    log_success "Kernel watch limits increased and unattended-upgrades disabled."
}

ensure_sufficient_memory() {
    log_info "Phase 0.5: Checking system RAM and configuring Swap..."
    
    local total_ram_mb
    total_ram_mb=$(free -m | awk '/^Mem:/{print $2}')
    local min_ram_mb=32768 # 32 GB threshold (32 * 1024 MB)
    local target_swap_mb=8192 # 8 GB target swap (8 * 1024 MB)
    
    log_info "Detected physical RAM: ${total_ram_mb} MB"
    
    if [ "$total_ram_mb" -lt "$min_ram_mb" ]; then
        log_warn "System RAM (${total_ram_mb} MB) is below recommended 32 GB (${min_ram_mb} MB)."
        
        local total_swap_mb
        total_swap_mb=$(free -m | awk '/^Swap:/{print $2}')
        
        if [ "$total_swap_mb" -ge "$target_swap_mb" ]; then
            log_success "Sufficient Swap space (${total_swap_mb} MB) is already configured."
        else
            log_info "Configuring an 8 GB swap file to prevent OOM errors..."
            
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
            
            log_success "8 GB swap file successfully enabled and configured."
        fi
    else
        log_success "Sufficient physical RAM detected (32 GB+)."
    fi
}

create_repo_structure() {
    log_info "Phase 1: Ensuring repository directory structure..."
    local base_dir
    base_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
             "$base_dir"/proto \
             "$base_dir"/inventory/devices 

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
        rm -f get-docker.sh
        log_success "Docker installed."
    fi

    local TARGET_USER="${SUDO_USER:-$USER}"
    if ! id -nG "$TARGET_USER" | grep -qw docker; then
        sudo usermod -aG docker "$TARGET_USER"
        log_warn "Added $TARGET_USER to docker group."
    fi

    # Verify docker socket access without sudo
    if ! docker ps >/dev/null 2>&1; then
        log_warn "Docker socket permission check failed in active shell session."
        
        # Attempt to seamlessly re-exec script with docker group context
        if sg docker -c "docker ps >/dev/null 2>&1"; then
            log_info "Refreshing group context and re-launching bootstrap..."
            exec sg docker -c "bash \"$0\" \"$@\""
        else
            log_error "Docker permissions could not be applied dynamically."
            log_error "Please log out and log back in (or reboot the machine), then re-run:"
            log_error "  ./$(basename "$0")"
            exit 1
        fi
    else
        log_success "Docker socket permissions verified."
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
    if [ -f "/etc/sysctl.d/99-sdn-uonos.conf" ] && [ -f "/etc/systemd/system/sdn-boot-recovery.service" ] && dpkg -l | grep -qw iptables-persistent; then
        log_success "Persistent SDN networking and boot recovery service are already configured."
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

    # Systemd service for reboot recovery
    cat <<EOF | sudo tee /etc/systemd/system/sdn-boot-recovery.service >/dev/null
[Unit]
Description=SDN Architecture Boot Network Recovery
After=k3s.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'iptables -P FORWARD ACCEPT && sysctl -w net.ipv4.ip_forward=1'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable sdn-boot-recovery.service
    log_success "SDN persistent networking configured."
}

setup_helm_repos() {
    if helm repo list 2>/dev/null | grep -q "atomix" && \
       helm repo list 2>/dev/null | grep -q "onosproject" && \
       helm repo list 2>/dev/null | grep -q "towards5gs"; then
        log_success "Helm repositories are already configured."
        return 0
    fi
    log_info "Phase 4: Setting up Helm repositories for µONOS..."
    
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
        wget -q https://github.com/fullstorydev/grpcurl/releases/download/v1.8.7/grpcurl_1.8.7_linux_x86_64.tar.gz
        tar -xvf grpcurl_1.8.7_linux_x86_64.tar.gz >/dev/null
        sudo mv grpcurl /usr/local/bin/
        rm -f grpcurl_1.8.7_linux_x86_64.tar.gz LICENSE
    fi
    if ! command -v gnmic >/dev/null 2>&1; then
        log_info "Installing gnmic CLI tool..."
        # Pin version to match what works with µONOS TLS
        GNMIC_VERSION="0.49.0"
        ARCH=$(uname -m)
        case "$ARCH" in
            x86_64) GNMIC_ARCH="x86_64" ;;
            aarch64) GNMIC_ARCH="aarch64" ;;
        esac
        curl -sSL -o /tmp/gnmic.tar.gz \
            "https://github.com/openconfig/gnmic/releases/download/v${GNMIC_VERSION}/gnmic_${GNMIC_VERSION}_linux_${GNMIC_ARCH}.tar.gz"
        sudo tar xzf /tmp/gnmic.tar.gz -C /usr/local/bin gnmic
        sudo chmod +x /usr/local/bin/gnmic
        rm -f /tmp/gnmic.tar.gz
        log_success "gnmic ${GNMIC_VERSION} installed."
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

    # Ensure CoreDNS deployment exists before patching
    if ! kubectl get deployment coredns -n kube-system >/dev/null 2>&1; then
        log_warn "CoreDNS deployment missing. Restoring from K3s manifests..."
        if sudo test -f /var/lib/rancher/k3s/server/manifests/coredns.yaml; then
            sudo kubectl apply -f /var/lib/rancher/k3s/server/manifests/coredns.yaml
        else
            sudo systemctl restart k3s
        fi
        sleep 5
    fi
    
    log_info "Ensuring host DNS and configuring CoreDNS upstream servers..."
    sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

    # 1. Restore host DNS fallback if dnscore removal broke /etc/resolv.conf
    if ! grep -qE '8.8.8.8|1.1.1.1' /etc/resolv.conf; then
        log_info "Adding public resolvers to host /etc/resolv.conf..."
        echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" | sudo tee -a /etc/resolv.conf >/dev/null
    fi

    # 2. Patch CoreDNS to bypass host resolv.conf
    kubectl get configmap coredns -n kube-system -o json 2>/dev/null | \
        sed 's/forward . \/etc\/resolv.conf/forward . 8.8.8.8 1.1.1.1/' | \
        kubectl apply -f - >/dev/null 2>&1 || true

    # 3. Restart CoreDNS and block until pods are fully Running & Ready
    log_info "Restarting CoreDNS and waiting for readiness..."
    kubectl rollout restart deployment coredns -n kube-system >/dev/null 2>&1 || true
    kubectl rollout status deployment coredns -n kube-system --timeout=120s || {
        log_error "CoreDNS failed to start. Check cluster logs with 'kubectl logs -n kube-system -l k8s-app=kube-dns'."
        exit 1
    }
    log_success "CoreDNS is running and resolving DNS requests."

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

    JUJU_BASE="ubuntu@22.04"

    log_info "Bootstrapping Juju Controller with base ${JUJU_BASE}..."
    juju bootstrap k8s-cloud osm-vca \
        --config default-base=$JUJU_BASE \
        --model-default default-base=$JUJU_BASE || true

    kill $CERT_SYNC_PID 2>/dev/null || true
    
    log_info "Adding 'osm' model on k8s-cloud with forced default base..."
    juju add-model osm k8s-cloud --config default-base=$JUJU_BASE || true

    log_info "Deploying Charmed OSM microservices with charm-specific bases..."

    juju deploy zookeeper-k8s --channel latest/stable --base ubuntu@20.04 --trust
    juju deploy ch:kafka-k8s --channel latest/stable --base ubuntu@20.04 --trust
    juju deploy mongodb-k8s --channel 6/stable --base ubuntu@22.04 --trust
    juju deploy charmed-osm-mariadb-k8s mariadb-k8s --channel latest/stable --base ubuntu@20.04 --trust
    juju deploy osm-prometheus prometheus-k8s --channel 14.0/stable --base ubuntu@20.04 --trust

    juju deploy osm-keystone keystone-k8s --channel latest/stable --base ubuntu@20.04 --resource keystone-image=opensourcemano/keystone:14 --trust
    juju deploy osm-nbi nbi-k8s --channel 14.0/stable --base ubuntu@22.04 --trust
    juju deploy osm-lcm lcm-k8s --channel 14.0/stable --base ubuntu@22.04 --trust
    juju deploy osm-ro ro-k8s --channel 14.0/stable --base ubuntu@22.04 --trust
    juju deploy osm-mon mon-k8s --channel 14.0/stable --base ubuntu@22.04 --trust
    juju deploy osm-pol pol-k8s --channel 14.0/stable --base ubuntu@22.04 --trust
    juju deploy osm-ng-ui ng-ui-k8s --channel 14.0/stable --base ubuntu@22.04 --trust

    juju deploy traefik-k8s --channel 1.0/stable --base ubuntu@20.04 --trust || true
    juju config traefik-k8s external_hostname="127.0.0.1.nip.io" || true
    juju config nbi-k8s external-hostname="nbi.127.0.0.1.nip.io" || true

    until ! juju status -m osm | grep -q "allocating"; do
        echo "Waiting for Juju allocation to finish... (check: juju status -m osm --watch 5s)"
        sleep 15
    done
    
    log_info "Integrating OSM microservices..."

    juju integrate zookeeper-k8s kafka-k8s || true
    juju integrate mariadb-k8s keystone-k8s || true
    juju integrate mariadb-k8s pol-k8s || true
    juju integrate mongodb-k8s nbi-k8s || true
    juju integrate mongodb-k8s lcm-k8s || true
    juju integrate mongodb-k8s ro-k8s || true
    juju integrate mongodb-k8s mon-k8s || true
    juju integrate mongodb-k8s pol-k8s || true
    juju integrate kafka-k8s nbi-k8s || true
    juju integrate kafka-k8s lcm-k8s || true
    juju integrate kafka-k8s mon-k8s || true
    juju integrate kafka-k8s pol-k8s || true
    juju integrate kafka-k8s ro-k8s || true
    juju integrate prometheus-k8s mon-k8s || true
    juju integrate prometheus-k8s nbi-k8s || true
    juju integrate keystone-k8s nbi-k8s || true
    juju integrate keystone-k8s mon-k8s || true
    juju integrate ro-k8s lcm-k8s || true
    juju integrate nbi-k8s ng-ui-k8s || true
    juju integrate nbi-k8s:ingress traefik-k8s:ingress || true
    
    log_info "Waiting for relations to settle..."
    sleep 20
    
    juju resolve keystone-k8s/0 2>/dev/null || true

    log_success "OSM deployment and integrations initiated successfully."
}

setup_sdn_python_client() {
    log_info "Phase 7: Provisioning Python environment and compiling Protobuf stubs..."

    local repo_dir
    repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local venv_dir="${repo_dir}/.venv"
    local proto_dir="${repo_dir}/proto"

    # 1. Create the project virtual environment if it doesn't exist
    if [ ! -x "${venv_dir}/bin/python" ]; then
        log_info "Creating project virtual environment at ${venv_dir}..."
        python3 -m venv "${venv_dir}"
    fi

    # 2. Install/upgrade the Python dependencies needed for gNMI stub generation
    log_info "Installing Python dependencies (grpcio, grpcio-tools, protobuf)..."
    "${venv_dir}/bin/pip" install --upgrade pip setuptools wheel
    "${venv_dir}/bin/pip" install --upgrade --force-reinstall \
        grpcio grpcio-tools protobuf

    # 3. Fetch OpenConfig gNMI schemas from a pinned revision (v0.9.1).
    #    gnmi.proto at this tag imports gnmi_ext.proto via the Go-style
    #    package path "github.com/openconfig/gnmi/proto/gnmi_ext/gnmi_ext.proto",
    #    so gnmi_ext.proto must live at the matching nested path.
    local ext_nested="${proto_dir}/github.com/openconfig/gnmi/proto/gnmi_ext"
    mkdir -p "$ext_nested"

    if [ ! -f "$proto_dir/gnmi.proto" ]; then
        log_info "Downloading gnmi.proto (v0.9.1)..."
        curl -fsSL https://raw.githubusercontent.com/openconfig/gnmi/v0.9.1/proto/gnmi/gnmi.proto \
            -o "$proto_dir/gnmi.proto"
    fi

    if [ ! -f "$ext_nested/gnmi_ext.proto" ]; then
        log_info "Downloading gnmi_ext.proto (v0.9.1)..."
        curl -fsSL https://raw.githubusercontent.com/openconfig/gnmi/v0.9.1/proto/gnmi_ext/gnmi_ext.proto \
            -o "$ext_nested/gnmi_ext.proto"
    fi

    # 4. Compile both proto files into Python stubs
    log_info "Compiling gNMI Protobuf stubs..."
    "$venv_dir/bin/python" -m grpc_tools.protoc \
        -I"$proto_dir" \
        --python_out="$proto_dir" \
        --grpc_python_out="$proto_dir" \
        "$proto_dir/gnmi.proto" \
        "$ext_nested/gnmi_ext.proto"

    # 5. Drop Python package markers along the nested gNMI extension path
    touch "$proto_dir/__init__.py"
    for d in github github/com github/com/openconfig github/com/openconfig/gnmi \
             github/com/openconfig/gnmi/proto github/com/openconfig/gnmi/proto/gnmi_ext; do
        mkdir -p "$proto_dir/$d"
        touch "$proto_dir/$d/__init__.py"
    done

    log_success "Protobuf stubs successfully generated."

    # 5. Make execution scripts executable
    chmod +x "$repo_dir"/tests/e2e-path-provisioning/* 2>/dev/null || true
    chmod +x "$repo_dir"/hardware-agents/switch-drivers/* 2>/dev/null || true
    chmod +x "$repo_dir"/hardware-agents/gnoi-targets/* 2>/dev/null || true
    chmod +x "$repo_dir"/hardware-agents/gnmi-targets/* 2>/dev/null || true
    chmod +x "$repo_dir"/hardware-agents/netconf-servers/* 2>/dev/null || true

    log_success "Python environment and Protobuf stubs initialized."
}

build_quantum_switching_plugin() {
    log_info "Phase 7.5: Building Quantum-Switching model plugin image (pre-µONOS)..."

    local repo_dir
    repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    local PLUGIN_DIR="${repo_dir}/sdn-controller/northbound-interfaces/model-plugin"
    local YANG_SRC="${repo_dir}/orchestration/yang-models/controller-quantum-switching.yang"
    local YANG_DST="${PLUGIN_DIR}/yang/controller-quantum-switching.yang"
    local PLUGIN_VERSION="1.0.0"
    local PLUGIN_IMAGE="onosproject/controller-quantum-switching:${PLUGIN_VERSION}-controller-quantum-switching-${PLUGIN_VERSION}"

    if ! command -v docker >/dev/null 2>&1; then
        log_error "docker not available; cannot build model plugin."
    fi

    if [ ! -f "${YANG_SRC}" ]; then
        log_error "YANG model not found at ${YANG_SRC}"
    fi

    mkdir -p "${PLUGIN_DIR}/yang"
    log_info "Copying ${YANG_SRC} → ${YANG_DST}"
    cp "${YANG_SRC}" "${YANG_DST}"

    # Derive the revision from the YANG file so metadata never drifts
    local YANG_REVISION
    YANG_REVISION=$(grep -oE 'revision[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}' "${YANG_DST}" \
                    | head -n1 | awk '{print $2}')
    YANG_REVISION=${YANG_REVISION:-2026-08-29}

    cat > "${PLUGIN_DIR}/metadata.yaml" <<EOF
name: controller-quantum-switching
version: ${PLUGIN_VERSION}
contactName: "SDN Architecture Team"
licenseName: "Apache-2.0"
artifactName: controller-quantum-switching
goPackage: github.com/onosproject/controller-quantum-switching
modules:
  - name: controller-quantum-switching
    organization: custom
    revision: "${YANG_REVISION}"
    file: controller-quantum-switching.yang
EOF

    log_info "Running onosproject/model-compiler to generate Go code..."
    local PLUGIN_DIR_ABS
    PLUGIN_DIR_ABS=$(realpath "${PLUGIN_DIR}")
    docker run --rm -v "${PLUGIN_DIR_ABS}:/config-model" \
        onosproject/model-compiler:v0.11.13

    sudo chown -R "$(id -u):$(id -g)" "${PLUGIN_DIR}"

    echo "${PLUGIN_VERSION}" > "${PLUGIN_DIR}/VERSION"

    if [ ! -f "${PLUGIN_DIR}/Makefile" ]; then
        log_error "model-compiler did not produce a Makefile in ${PLUGIN_DIR}. YANG model likely has errors."
    fi

    # Fix the pinned libc6-compat version that no longer exists in Alpine 3.17
    if [ -f "${PLUGIN_DIR}/Dockerfile" ]; then
        sed -i 's/libc6-compat=[0-9.]*-r[0-9]*/libc6-compat/g' "${PLUGIN_DIR}/Dockerfile"
    fi

    log_info "Building plugin image ${PLUGIN_IMAGE}..."
    ( cd "${PLUGIN_DIR}" && make image ) || log_error "Failed to build model plugin image."

    if ! docker images --format '{{.Repository}}:{{.Tag}}' | grep -qF "${PLUGIN_IMAGE}"; then
        docker images | grep controller-quantum-switching || true
        log_error "Expected image ${PLUGIN_IMAGE} was not produced."
    fi

    log_info "Importing ${PLUGIN_IMAGE} into K3s containerd..."
    docker save "${PLUGIN_IMAGE}" | sudo k3s ctr images import - || true

    if ! sudo k3s ctr images ls -q | grep -qF "docker.io/${PLUGIN_IMAGE}"; then
        log_error "${PLUGIN_IMAGE} is not present in K3s containerd after import."
    fi

    log_success "Quantum-Switching model plugin built and imported into K3s."
}

patch_all_uonos_secrets() {
    log_info "Phase 7.8: Overwriting cert bundles in every µONOS Secret..."

    local repo_dir
    repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local cert_dir="${repo_dir}/.certs/uonos"
    local ns="micro-onos"

    if [ ! -s "$cert_dir/tls.crt" ] || [ ! -s "$cert_dir/tls.key" ]; then
        log_error "Canonical certs missing in $cert_dir; cannot patch secrets."
    fi

    local tls_crt_b64 tls_key_b64 ca_b64 client_crt_b64 client_key_b64
    tls_crt_b64=$(base64 -w0 "$cert_dir/tls.crt")
    tls_key_b64=$(base64 -w0 "$cert_dir/tls.key")
    ca_b64=$(base64 -w0 "$cert_dir/tls.cacrt")
    client_crt_b64=$(base64 -w0 "$cert_dir/client1.crt")
    client_key_b64=$(base64 -w0 "$cert_dir/client1.key")

    local secrets
    secrets=$(kubectl get secrets -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)

    local patched=0
    for secret in $secrets; do
        local has_tls_key has_client_key
        has_tls_key=$(kubectl get secret "$secret" -n "$ns" \
            -o jsonpath='{.data.tls\.key}' 2>/dev/null | wc -c)
        has_client_key=$(kubectl get secret "$secret" -n "$ns" \
            -o jsonpath='{.data.client1\.key}' 2>/dev/null | wc -c)

        if [ "$has_tls_key" -gt 0 ]; then
            log_info "  Overwriting tls.* bundle in $secret"
            kubectl patch secret "$secret" -n "$ns" --type=merge \
                -p "{\"data\":{\"tls.crt\":\"$tls_crt_b64\",\"tls.key\":\"$tls_key_b64\",\"tls.cacrt\":\"$ca_b64\"}}" \
                >/dev/null
            patched=$((patched + 1))
        fi
        if [ "$has_client_key" -gt 0 ]; then
            log_info "  Overwriting client1.* bundle in $secret"
            kubectl patch secret "$secret" -n "$ns" --type=merge \
                -p "{\"data\":{\"client1.crt\":\"$client_crt_b64\",\"client1.key\":\"$client_key_b64\",\"client1.cacrt\":\"$ca_b64\"}}" \
                >/dev/null
            patched=$((patched + 1))
        fi
    done

    log_success "Overwrote cert bundles in $patched Secret(s)."
}

mount_onos_cli_certs() {
    log_info "Phase 7.9: Mounting our certs into onos-cli..."

    local repo_dir
    repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local cert_dir="${repo_dir}/.certs/uonos"
    local ns="micro-onos"

    if [ ! -s "$cert_dir/tls.cacrt" ]; then
        log_error "Missing $cert_dir/tls.cacrt; cannot mount certs into onos-cli."
    fi

    # Ensure onfca.crt is present in the Secret under the name the pod reads
    kubectl patch secret onos-cli-secret -n "$ns" --type=merge \
        -p "{\"data\":{\"onfca.crt\":\"$(base64 -w0 "$cert_dir/tls.cacrt")\"}}" \
        >/dev/null

    # Add the Secret volume and the three subPath mounts if not already present
    if ! kubectl get deployment onos-cli -n "$ns" \
            -o jsonpath='{.spec.template.spec.volumes[?(@.name=="onos-cli-certs")].name}' \
            2>/dev/null | grep -q onos-cli-certs; then
        log_info "  Adding onos-cli-certs volume + subPath mounts to onos-cli Deployment"
        kubectl patch deployment onos-cli -n "$ns" --type=strategic -p '
spec:
  template:
    spec:
      volumes:
      - name: onos-cli-certs
        secret:
          secretName: onos-cli-secret
          defaultMode: 420
      containers:
      - name: onos-cli
        volumeMounts:
        - name: onos-cli-certs
          mountPath: /etc/ssl/certs/client1.crt
          subPath: client1.crt
          readOnly: true
        - name: onos-cli-certs
          mountPath: /etc/ssl/certs/client1.key
          subPath: client1.key
          readOnly: true
        - name: onos-cli-certs
          mountPath: /etc/ssl/certs/onfca.crt
          subPath: onfca.crt
          readOnly: true
'
    else
        log_info "  onos-cli already has the onos-cli-certs volume; refreshing Secret and rolling out."
        kubectl rollout restart deployment/onos-cli -n "$ns" >/dev/null 2>&1 || true
    fi

    kubectl rollout status deployment/onos-cli -n "$ns" --timeout=120s || \
        log_warn "onos-cli rollout did not complete in time."

    log_success "onos-cli now uses our certs and trusts our CA."
}

generate_uonos_certs() {
    log_info "Phase 7.7: Generating µONOS TLS certificates with openssl..."

    local repo_dir
    repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local cert_dir="${repo_dir}/.certs/uonos"
    local ns="micro-onos"

    if ! command -v openssl >/dev/null 2>&1; then
        log_error "openssl not available; cannot generate certificates."
    fi

    rm -rf "$cert_dir"
    mkdir -p "$cert_dir"
    chmod 700 "$cert_dir"

    # --- CA ---
    openssl genrsa -out "$cert_dir/ca.key" 4096 2>/dev/null
    openssl req -x509 -new -nodes -key "$cert_dir/ca.key" -sha256 -days 3650 \
        -subj "/C=US/ST=CA/L=Menlo Park/O=ONF/OU=Engineering/CN=ca.opennetworking.org" \
        -out "$cert_dir/tls.cacrt"

    # --- Server cert ---
    cat > "$cert_dir/server.ext" <<'EOF'
subjectAltName=DNS:onos-config,DNS:onos-config.opennetworking.org,DNS:onos-config.micro-onos,DNS:onos-config.micro-onos.svc,DNS:onos-config.micro-onos.svc.cluster.local,DNS:onos-topo,DNS:onos-topo.micro-onos,DNS:localhost,IP:127.0.0.1
extendedKeyUsage=serverAuth,clientAuth
EOF

    openssl genrsa -out "$cert_dir/tls.key" 4096 2>/dev/null
    openssl req -new -key "$cert_dir/tls.key" \
        -subj "/C=US/ST=CA/L=Menlo Park/O=ONF/OU=Engineering/CN=onos-config.opennetworking.org" \
        -out "$cert_dir/server.csr"
    openssl x509 -req -in "$cert_dir/server.csr" \
        -CA "$cert_dir/tls.cacrt" -CAkey "$cert_dir/ca.key" -CAcreateserial \
        -out "$cert_dir/tls.crt" -days 3650 -sha256 \
        -extfile "$cert_dir/server.ext" 2>/dev/null

    # --- Client cert ---
    cat > "$cert_dir/client.ext" <<'EOF'
extendedKeyUsage=clientAuth
EOF

    openssl genrsa -out "$cert_dir/client1.key" 4096 2>/dev/null
    openssl req -new -key "$cert_dir/client1.key" \
        -subj "/C=US/ST=CA/L=Menlo Park/O=ONF/OU=Engineering/CN=client1" \
        -out "$cert_dir/client1.csr"
    openssl x509 -req -in "$cert_dir/client1.csr" \
        -CA "$cert_dir/tls.cacrt" -CAkey "$cert_dir/ca.key" -CAcreateserial \
        -out "$cert_dir/client1.crt" -days 3650 -sha256 \
        -extfile "$cert_dir/client.ext" 2>/dev/null

    # --- Sanity ---
    local f
    for f in tls.crt tls.key tls.cacrt client1.crt client1.key; do
        if [ ! -s "$cert_dir/$f" ]; then
            log_error "Cert generation failed: $f missing or empty in $cert_dir"
        fi
    done

    kubectl create namespace "$ns" 2>/dev/null || true

    log_info "Installing onos-config-secret (tls.crt, tls.key, tls.cacrt)..."
    kubectl create secret generic onos-config-secret -n "$ns" \
        --from-file=tls.crt="$cert_dir/tls.crt" \
        --from-file=tls.key="$cert_dir/tls.key" \
        --from-file=tls.cacrt="$cert_dir/tls.cacrt" \
        --dry-run=client -o yaml | kubectl apply -f -

    log_info "Installing onos-cli-secret (client1.crt, client1.key, client1.cacrt)..."
    kubectl create secret generic onos-cli-secret -n "$ns" \
        --from-file=client1.crt="$cert_dir/client1.crt" \
        --from-file=client1.key="$cert_dir/client1.key" \
        --from-file=client1.cacrt="$cert_dir/tls.cacrt" \
        --dry-run=client -o yaml | kubectl apply -f -

    log_info "Installing onos-topo-secret (shared server cert)..."
    kubectl create secret generic onos-topo-secret -n "$ns" \
        --from-file=tls.crt="$cert_dir/tls.crt" \
        --from-file=tls.key="$cert_dir/tls.key" \
        --from-file=tls.cacrt="$cert_dir/tls.cacrt" \
        --dry-run=client -o yaml | kubectl apply -f -

    log_success "µONOS TLS certificates generated and secrets installed."
}

deploy_cloud_native_uonos() {
    log_info "Phase 8: Evaluating µONOS and Atomix deployment state..."

    local uonos_active=false
    if kubectl get ns micro-onos >/dev/null 2>&1 && \
       kubectl get pods -n micro-onos 2>/dev/null | grep -qE 'onos-topo|onos-config|restconf-gateway'; then
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

    log_info "=== Installing µONOS ==="
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local ONOS_HELM_DIR="$SCRIPT_DIR/onos-helm-charts"

    if [ ! -d "$ONOS_HELM_DIR" ]; then
        log_error "ONOS Helm repository not found at $ONOS_HELM_DIR"
        log_error "The repository must be present locally; it will not be cloned automatically."
        exit 1
    fi

    log_info "Using local ONOS Helm repository: $ONOS_HELM_DIR"
    log_info "Purging any existing onos-umbrella release and micro-onos namespace..."
    helm uninstall onos-umbrella -n micro-onos 2>/dev/null || true
    kubectl delete namespace micro-onos --force --grace-period=0 2>/dev/null || true
    while kubectl get namespace micro-onos >/dev/null 2>&1; do
        log_info "Waiting for micro-onos namespace to terminate..."
        sleep 2
    done

    (
        cd "$ONOS_HELM_DIR" || exit 1

        log_info "Building ONOS Helm dependencies..."
        helm dependency build ./onos-umbrella || {
            log_error "Failed to build ONOS Helm dependencies."
            exit 1
        }

        log_info "Installing Atomix 1.1.2..."
        helm upgrade --install atomix atomix/atomix \
            --version 1.1.2 \
            -n kube-system || {
            log_error "Failed to install Atomix."
            exit 1
        }

        log_info "Creating micro-onos namespace..."
        kubectl create namespace micro-onos 2>/dev/null || true

        log_info "Installing µONOS..."
        OVERRIDE_VALUES="./onos-umbrella/values-quantum-sdn.yaml"
        if [ ! -f "${OVERRIDE_VALUES}" ]; then
            log_error "Missing ${OVERRIDE_VALUES}"
            exit 1
        fi

        log_info "Purging any stale µONOS TLS secrets so cert-issuer regenerates them..."
        kubectl delete secret -n micro-onos --ignore-not-found \
            onos-config-secret \
            onos-cli-secret \
            onos-topo-secret \
            onos-umbrella-secret 2>/dev/null || true

        log_info "Purging any stale cert-issuer Job..."
        kubectl delete job -n micro-onos --ignore-not-found \
            onos-umbrella-cert-issuer \
            cert-issuer 2>/dev/null || true

        helm upgrade --install onos-umbrella ./onos-umbrella \
            -n micro-onos \
            -f "${OVERRIDE_VALUES}" || {
            log_error "Failed to install µONOS."
            exit 1
        }
    ) || exit 1

    # -----------------------------------------------------------------
    # Certificates: the chart's cert-issuer writes an incomplete bundle
    # (tls.cacrt + tls.key but no tls.crt) and runs as an async
    # post-install hook, so its Secrets appear AFTER helm returns.
    # Strategy:
    #   1. Generate our own matching triplet with openssl.
    #   2. Overwrite every Secret that already exists.
    #   3. Wait for the per-component Secrets the hook creates.
    #   4. Overwrite those too, so key+cert always match.
    #   5. Restart every pod that mounts a TLS Secret.
    # -----------------------------------------------------------------

    log_info "Generating matching µONOS TLS certs with openssl..."
    generate_uonos_certs

    log_info "Overwriting cert bundles in Secrets that already exist..."
    patch_all_uonos_secrets

    log_info "Waiting for chart-generated component Secrets to appear..."
    for i in $(seq 1 60); do
        all_present=true
        for s in onos-umbrella-topo-discovery-secret \
                 onos-umbrella-device-provisioner-secret ; do
            kubectl get secret "$s" -n micro-onos >/dev/null 2>&1 || all_present=false
        done
        [ "$all_present" = true ] && break
        sleep 2
    done

    log_info "Overwriting cert bundles in chart-generated component Secrets..."
    patch_all_uonos_secrets

        log_info "Restarting all µONOS pods so they pick up the matching CAs..."
    # Every pod created by the onos-umbrella Helm release carries
    # app.kubernetes.io/instance=onos-umbrella. Deleting by that one
    # label restarts onos-config, onos-topo, onos-cli, topo-discovery,
    # device-provisioner, and the three consensus pods in one shot,
    # regardless of how the chart changes per-component name labels
    # between versions.
    log_info "Restarting consensus pods one at a time to allow leader election..."
    for i in 0 1 2; do
        kubectl delete pod -n micro-onos "onos-umbrella-consensus-${i}" \
            --grace-period=0 --force 2>/dev/null || true
        kubectl wait --for=condition=Ready "pod/onos-umbrella-consensus-${i}" \
            -n micro-onos --timeout=180s 2>/dev/null || \
            log_warn "  consensus-${i} did not become Ready in 180s"
        sleep 10
    done
    
    log_info "Restarting remaining µONOS pods..."
    for label in \
        app.kubernetes.io/name=onos-config \
        app.kubernetes.io/name=onos-cli \
        app.kubernetes.io/name=onos-topo \
        app.kubernetes.io/name=topo-discovery \
        app.kubernetes.io/name=device-provisioner ; do
        kubectl delete pod -n micro-onos -l "$label" \
            --grace-period=0 --force 2>/dev/null || true
    done
    
    sleep 10
    
    mount_onos_cli_certs
    
    log_info "=== µONOS installation completed ==="

    # Wait for the onos-cli and onos-config pods to be scheduled and Ready
    # before trying to extract certs from them.
    log_info "Waiting for onos-cli and onos-config pods to be Ready..."
    local waited=0
    local timeout=600
    local cli_pod=""
    local config_pod=""

    while [ "$waited" -lt "$timeout" ]; do
        cli_pod=$(kubectl get pods -n micro-onos -l app.kubernetes.io/name=onos-cli \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        config_pod=$(kubectl get pods -n micro-onos -l app.kubernetes.io/name=onos-config \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

        if [ -n "$cli_pod" ] && [ -n "$config_pod" ]; then
            if kubectl wait --for=condition=Ready pod/"$cli_pod" -n micro-onos --timeout=10s >/dev/null 2>&1 && \
               kubectl wait --for=condition=Ready pod/"$config_pod" -n micro-onos --timeout=10s >/dev/null 2>&1; then
                break
            fi
        fi
        sleep 3
        waited=$((waited + 3))
    done

    if [ "$waited" -ge "$timeout" ]; then
        log_warn "Timed out waiting for onos-cli/onos-config pods after ${timeout}s."
        log_warn "Cert extraction may fail. Check:"
        log_warn "  kubectl get pods -n micro-onos"
    else
        log_success "onos-cli and onos-config pods are Ready (waited ${waited}s)."
    fi

    log_info "Building RESTCONF Gateway image..."
    if command -v docker >/dev/null 2>&1; then
        docker build -t quantum-restconf-gateway:1.0.0 \
            "$SCRIPT_DIR/sdn-controller/northbound-interfaces/restconf-gateway" \
            || log_error "Failed to build RESTCONF Gateway image."

        if command -v k3s >/dev/null 2>&1; then
            docker save quantum-restconf-gateway:1.0.0 \
                | sudo k3s ctr images import - \
                || log_warn "K3s image import for gateway failed (non-fatal)."
        fi
    else
        log_error "docker not available; cannot build RESTCONF Gateway image."
    fi

    log_info "Applying RESTCONF Gateway manifest..."
    kubectl apply -f \
        "$SCRIPT_DIR/sdn-controller/northbound-interfaces/restconf-gateway/deploy.yaml"

    log_info "Waiting for RESTCONF Gateway rollout..."
    kubectl rollout status deployment/restconf-gateway \
        -n micro-onos --timeout=120s \
        || log_error "RESTCONF Gateway failed to become Ready."

    log_success "RESTCONF Gateway deployed."

    # Copy the certs generate_uonos_certs just wrote to .certs/uonos/.
    # Extracting from the onos-cli pod is unreliable: the chart ships its
    # own secret mounted at the same path, so `kubectl exec -- cat` returns
    # the chart's cert (CN=client1.opennetworking.org), not ours
    # (CN=client1). Copying from .certs/uonos/ guarantees we install the
    # same triplet that was loaded into onos-config-secret.
    log_info "Installing µONOS certs into /etc/onos/certs/ from .certs/uonos/..."
    local cert_dir="${SCRIPT_DIR}/.certs/uonos"
    if [ ! -s "$cert_dir/client1.crt" ] || [ ! -s "$cert_dir/client1.key" ] || [ ! -s "$cert_dir/tls.cacrt" ]; then
        log_error "Cert triplet missing in $cert_dir; cannot install host certs."
    fi

    sudo mkdir -p /etc/onos/certs
    sudo cp "$cert_dir/client1.crt" /etc/onos/certs/client1.crt
    sudo cp "$cert_dir/client1.key" /etc/onos/certs/client1.key
    sudo cp "$cert_dir/tls.cacrt"  /etc/onos/certs/tls.cacrt

    sudo chown "${USER}:${USER}" /etc/onos/certs/client1.key
    sudo chmod 600 /etc/onos/certs/client1.key
    sudo chmod 644 /etc/onos/certs/client1.crt /etc/onos/certs/tls.cacrt

    log_success "Certificates installed to /etc/onos/certs/ (key owned by ${USER})."

    # Write a gnmic config that mirrors what we use interactively.
    # The client identity is client1.crt/client1.key.
    sudo mkdir -p /etc/gnmic
    cat << 'EOF' | sudo tee /etc/gnmic/gnmic.yaml > /dev/null
username: ""
password: ""
skip-verify: true
encoding: JSON_IETF
tls-cert: /etc/onos/certs/client1.crt
tls-key: /etc/onos/certs/client1.key
EOF
    sudo chmod 644 /etc/gnmic/gnmic.yaml

    log_success "gnmic mTLS configuration generated successfully."
}

deploy_sdn_adapter_and_topo_aspects() {
    log_info "Phase 8.6: Deploying SDN Adapter & Setting Topology Endpoints..."

    local base_dir
    base_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local adapter_dir="${base_dir}/sdn-controller/southbound-plugins/sdn-adapter"

    # 1. Build and import the SDN Adapter container image
    if [ -f "${adapter_dir}/Dockerfile" ]; then
        log_info "Building sdn-adapter Docker image..."
        docker build -t sdn-adapter:1.0.0 "${adapter_dir}" || log_error "Failed to build sdn-adapter image."

        if command -v k3s >/dev/null 2>&1; then
            log_info "Importing sdn-adapter image into K3s..."
            docker save sdn-adapter:1.0.0 2>/dev/null | sudo k3s ctr images import - || true
        fi
    else
        log_warn "Dockerfile for sdn-adapter not found at ${adapter_dir}/Dockerfile. Using fallback image."
    fi

    # 2. Deploy SDN Adapter from the tracked manifest
    log_info "Applying sdn-adapter manifest..."
    kubectl apply -f "${adapter_dir}/deploy.yaml"

    # 3. Wait for the sdn-adapter deployment to become ready
    log_info "Waiting for sdn-adapter pod to be ready..."
    kubectl rollout status deployment/sdn-adapter -n micro-onos --timeout=90s || {
        log_error "sdn-adapter failed to start."
        exit 1
    }

        # 4. Verify Python libraries inside the adapter
    log_info "Verifying SDN Adapter runtime environment..."
    kubectl exec -n micro-onos deployment/sdn-adapter -- python3 -c "import ncclient, grpc; print('SDN Adapter Ready')" || {
        log_error "SDN Adapter dependency verification failed."
        exit 1
    }

    # 4b. Probe the live HTTP API
    log_info "Probing sdn-adapter /healthz..."
    if ! kubectl exec -n micro-onos deployment/sdn-adapter -- \
            curl -sf http://localhost:8080/healthz >/dev/null; then
        log_error "SDN Adapter /healthz probe failed."
        exit 1
    fi

    # 5. Verify topology registration
    log_info "Verifying onos-topo configuration..."

    if kubectl exec -n micro-onos deployment/onos-cli -- \
        onos topo get entities \
            --service-address onos-topo:5150 \
            --tls-cert-path /etc/ssl/certs/client1.crt \
            --tls-key-path  /etc/ssl/certs/client1.key \
            >/dev/null 2>&1; then
        log_success "onos-topo inventory is accessible."
    else
        log_warn "Unable to query onos-topo inventory."
    fi

    log_success "SDN Adapter deployed successfully."
}

register_inventory_devices() {
    log_info "Phase 8.5: Registering current device inventory with µONOS..."

    # Wait until onos-config is Ready before we ask it about plugins.
    log_info "Ensuring onos-config is Ready before registering devices..."
    local cfg_pod
    cfg_pod=$(kubectl get pods -n micro-onos \
        -l app.kubernetes.io/name=onos-config \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [ -n "$cfg_pod" ]; then
        kubectl wait --for=condition=Ready pod/"$cfg_pod" \
            -n micro-onos --timeout=180s || \
            log_warn "onos-config not fully Ready before device registration; proceeding."
    fi

    if [ ! -f "./inventory/register-devices.sh" ]; then
        log_error "inventory/register-devices.sh not found."
        return 1
    fi

    if [ ! -f "./inventory/gnmi_set_with_ext.py" ]; then
        log_error "inventory/gnmi_set_with_ext.py not found."
        return 1
    fi

    if [ ! -d "./inventory/devices" ]; then
        log_error "inventory/devices directory not found."
        return 1
    fi

    chmod +x "./inventory/register-devices.sh"
    chmod +x "./inventory/gnmi_set_with_ext.py"
    ./inventory/register-devices.sh || {
        log_error "Device registration failed."
        return 1
    }

    log_success "µONOS device inventory registration completed."
}

deploy_open5gs() {
    log_info "Phase 9: Evaluating Open5GS deployment state..."

    local open5gs_active=false
    if helm list -n open5gs 2>/dev/null | grep -q "open5gs" || kubectl get pods -n open5gs 2>/dev/null | grep -q "open5gs"; then
        open5gs_active=true
    fi

    if [ "$open5gs_active" = true ]; then
        log_success "Open5GS is already deployed in namespace 'open5gs'."
        if ! ask_user "Do you want to re-install / upgrade Open5GS?" "N"; then
            log_info "Skipping Open5GS re-installation."
            return 0
        fi
        
        log_info "Purging existing Open5GS release and pods for a clean install..."
        helm uninstall open5gs -n open5gs 2>/dev/null || true
        kubectl delete pods --all -n open5gs --grace-period=0 --force 2>/dev/null || true
    else
        log_info "Open5GS is not currently deployed. Proceeding with installation..."
    fi

    kubectl create namespace open5gs --dry-run=client -o yaml | kubectl apply -f -

    log_info "Installing Open5GS using Helm (Gradiant OCI)..."
    if helm install open5gs oci://registry-1.docker.io/gradiantcharts/open5gs -n open5gs; then
        log_success "Open5GS Helm release deployed successfully."
    else
        log_warn "Failed to install Open5GS chart from Gradiant repository."
    fi
}

verify_uonos_gnmi_end_to_end() {
    log_info "Phase 10: Verifying µONOS gNMI end-to-end connectivity..."

    CLI_POD=$(kubectl get pods -n micro-onos -l app.kubernetes.io/name=onos-cli \
    -o jsonpath='{.items[0].metadata.name}')
    if [ -z "$CLI_POD" ]; then
        log_warn "onos-cli pod not found; skipping gNMI verification."
        return 0
    fi

    # Copy gnmic into the onos-cli pod if not already present
    if ! kubectl exec -n micro-onos "$CLI_POD" -- test -x /tmp/gnmic 2>/dev/null; then
        log_info "Installing gnmic into onos-cli pod for verification..."
        kubectl exec -n micro-onos "$CLI_POD" -- sh -c '
            curl -sSL -o /tmp/gnmic.tar.gz \
              https://github.com/openconfig/gnmic/releases/download/v0.49.0/gnmic_0.49.0_linux_x86_64.tar.gz &&
            tar xzf /tmp/gnmic.tar.gz -C /tmp &&
            chmod +x /tmp/gnmic
        ' || { log_warn "Could not install gnmic into pod; skipping verification."; return 0; }
    fi

    if kubectl exec -n micro-onos "$CLI_POD" -- \
        /tmp/gnmic -a onos-config.micro-onos.svc.cluster.local:5150 \
            --tls-cert /etc/ssl/certs/client1.crt \
            --tls-key  /etc/ssl/certs/client1.key \
            --skip-verify \
            capabilities >/dev/null 2>&1; then
        log_success "gNMI capabilities check passed."
    else
        log_warn "gNMI capabilities check failed. See above for details."
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
build_quantum_switching_plugin
deploy_cloud_native_uonos
deploy_sdn_adapter_and_topo_aspects
register_inventory_devices
verify_uonos_gnmi_end_to_end
deploy_open5gs

echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN} Setup Complete!${NC}"
echo -e "To view your µONOS Kubernetes pods and juju services, run:"
echo -e "  kubectl get pods -n osm -o wide -w"
echo -e "  kubectl get pods -n micro-onos -o wide -w"
echo -e "  kubectl get pods -n open5gs -o wide -w"
echo -e "  kubectl get pods -n kube-system -o wide -w"
echo -e "  kubectl get pods -n controller-osm-vca -o wide -w"
echo -e "  kubectl exec -n micro-onos deploy/onos-cli -- onos config get plugins \\"
echo -e "      --tls-cert-path /etc/ssl/certs/client1.crt --tls-key-path /etc/ssl/certs/client1.key"
echo -e "  kubectl exec -n micro-onos deploy/onos-cli -- onos topo get relations \\"
echo -e "      --service-address onos-topo:5150 \\"
echo -e "      --tls-cert-path /etc/ssl/certs/client1.crt --tls-key-path /etc/ssl/certs/client1.key"
echo -e "  kubectl exec -n micro-onos deploy/onos-cli -- onos config get configurations \\"
echo -e "      --tls-cert-path /etc/ssl/certs/client1.crt --tls-key-path /etc/ssl/certs/client1.key"
echo -e "  juju status --watch 5s"
echo -e "${GREEN}====================================================${NC}"
