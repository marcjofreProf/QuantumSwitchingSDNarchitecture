#!/bin/bash
# ---------------------------------------------------------------------------
# Quantum-SDN Switching Architecture Bootstrap Script
# ---------------------------------------------------------------------------
# This script scaffolds the repository structure and installs the required 
# cloud-native dependencies (K8s, Helm, Docker, Protoc, µONOS, Open5GS repos)
# for the 6G-OpenLab VM infrastructure.
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

# Function to prompt the user
ask_user() {
    local prompt="$1"
    local default="$2"
    local response
    
    if [ "$default" = "Y" ]; then
        read -p "$(echo -e "${YELLOW}${prompt} [Y/n]:${NC}")" response
        response=${response:-Y}
    else
        read -p "$(echo -e "${YELLOW}${prompt} [y/N]:${NC}")" response
        response=${response:-N}
    fi
    
    if [[ "$response" =~ ^[Yy]$ ]]; then
        return 0 # True
    else
        return 1 # False
    fi
}

# --- Phase 1: Repository Scaffolding ---
create_repo_structure() {
    log_info "Phase 1: Creating Quantum-SDN repository structure..."
    local base_dir="quantum-sdn-architecture"
    
    if [ -d "$base_dir" ]; then
        log_warn "Directory '$base_dir' already exists."
        if ! ask_user "Do you want to recreate/update the folders inside it?" "Y"; then
            log_info "Skipping directory creation."
            return
        fi
    fi

    mkdir -p $base_dir/{.github/workflows,docs/{architecture,api},deploy/{vm-provisioning,k8s-cluster},sdn-controller/{apps,southbound-plugins,northbound-interfaces},orchestration/{osm-packages,yang-models},workloads/open5gs,hardware-agents/{gnoi-targets,switch-drivers},tests/{latency-benchmarks,e2e-path-provisioning},scripts}
    
    # Create placeholder files
    touch $base_dir/README.md $base_dir/LICENSE$base_dir/Makefile
    
    log_success "Repository structure created successfully at ./$base_dir"
}

# --- Phase 2: System Dependencies ---
install_sys_deps() {
    log_info "Phase 2: Checking basic system dependencies (curl, git, wget, jq)..."
    local deps="curl git wget jq build-essential"
    local to_install=""

    for pkg in $deps; do
        if ! dpkg -l | grep -qw $pkg; then
            to_install="$to_install$pkg"
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

# --- Phase 3: Docker & Kubernetes (Kind) & Helm ---
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
        sudo usermod -aG docker $USER
        rm get-docker.sh
        log_success "Docker installed. (You may need to log out and log back in to use Docker without sudo)."
    fi
}

install_kubectl_and_helm() {
    log_info "Checking kubectl..."
    if command -v kubectl >/dev/null 2>&1; then
        log_success "kubectl is already installed ($(kubectl version --client --short 2>/dev/null | grep Client || echo "Version hidden"))."
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
    
    # Open5GS (Using the official Orange-OpenSource Towards5G Helm repo)
    helm repo add towards5g https://orange-opensource.github.io/towards5g-helm
    
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

    log_info "Checking grpcurl (useful for testing gRPC endpoints)..."
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
    log_warn "OSM is a highly complex orchestration platform that usually requires dedicated CPU/RAM."
    log_warn "It installs LXD, Juju, and multiple K8s pods."
    
    if ask_user "Do you want to download and run the OSM standalone installer now?" "N"; then
        log_info "Downloading OSM installer..."
        wget https://osm-download.etsi.org/ftp/osm-14.0-fourteen/install_osm.sh
        chmod +x install_osm.sh
        log_info "Running OSM installer (this may take up to 45 minutes)..."
        ./install_osm.sh
        log_success "OSM installation process finished."
    else
        log_info "Skipping OSM installation. You can deploy it later in the 6G-OpenLab VM."
    fi
}

# --- Main Execution block ---
echo -e "${CYAN}=======================================================${NC}"
echo -e "${CYAN}   Quantum-SDN Switching Architecture Environment Setup${NC}"
echo -e "${CYAN}=======================================================${NC}"

create_repo_structure
install_sys_deps
install_docker
install_kubectl_and_helm
setup_helm_repos
install_grpc_tools
install_osm_installer

echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN} Setup Complete!${NC}"
echo -e "Navigate to your new repository: ${YELLOW}cd quantum-sdn-architecture${NC}"
echo -e "Review Open5GS charts with: ${YELLOW}helm search repo towards5g${NC}"
echo -e "${GREEN}====================================================${NC}"
