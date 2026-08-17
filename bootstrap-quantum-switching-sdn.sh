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
    local base_dir="."

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

    log_success "Repository structure created/updated successfully."
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
            log_warn "Primary Helm installation script failed (GitHub rate-limit or SSL error). Attempting direct CDN binary fallback..."
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

# --- Phase 4: SDN Controller (µONOS) & Open5GS Repos ---
setup_helm_repos() {
    log_info "Phase 4: Setting up Helm repositories for µONOS and Open5GS..."

    # microONOS Repo
    helm repo add onosproject https://charts.onosproject.org || log_warn "Failed to add onosproject repository."

    # Towards5GS Repo with jsDelivr Fallback
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

    if ask_user "Do you want to download and run the OSM standalone installer now (for lightweigh deployment with no MANO, press n)?" "N"; then
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

# --- Phase 7: Setup Python gRPC Client Environment ---
setup_sdn_python_client() {
    log_info "Phase 7: Setting up Python gRPC SDN Client Environment..."
    local base_dir="."  # <--- MUST BE "."

    log_info "Installing Python venv package..."
    sudo apt-get install -y python3-venv python3-pip

    log_info "Creating Python virtual environment in $base_dir/.venv..."
    python3 -m venv "$base_dir/.venv"

    log_info "Installing grpcio and grpcio-tools in the virtual environment..."
    "$base_dir/.venv/bin/pip" install --upgrade pip
    "$base_dir/.venv/bin/pip" install grpcio grpcio-tools

    if [ -f "$base_dir/proto/quantum_switch.proto" ]; then
        log_info "Compiling gRPC stubs..."
        "$base_dir/.venv/bin/python" -m grpc_tools.protoc -I"$base_dir/proto" \
            --python_out="$base_dir/proto" \
            --grpc_python_out="$base_dir/proto" \
            "$base_dir/proto/quantum_switch.proto"

        touch "$base_dir/proto/__init__.py"
        log_success "Stubs compiled successfully."
    else
        log_warn "proto/quantum_switch.proto not found! Skipping compilation."
    fi
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
