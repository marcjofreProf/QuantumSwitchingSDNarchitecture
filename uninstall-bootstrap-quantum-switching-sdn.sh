#!/bin/bash
# ---------------------------------------------------------------------------
# Quantum-SDN Switching Architecture Teardown & Uninstall Script
# ---------------------------------------------------------------------------

set +e # Do not exit on error so all cleanup steps attempt to execute

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
log_error() { echo -e "${RED}[ERROR] $1${NC}"; }

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

echo -e "${RED}===========================================================${NC}"
echo -e "${RED}  Quantum-SDN Switching Architecture Environment Teardown  ${NC}"
echo -e "${RED}===========================================================${NC}"

if ! ask_user "Are you sure you want to uninstall tools and clean this repository?" "N"; then
    log_info "Teardown cancelled."
    exit 0
fi

# --- Phase 1: Python Virtual Environment & Stubs Cleanup ---
uninstall_python_env() {
    log_info "Phase 1: Removing Python virtual environment and compiled gRPC stubs..."
    local base_dir="."

    if [ -d "$base_dir/.venv" ]; then
        rm -rf "$base_dir/.venv"
        log_success "Removed $base_dir/.venv directory."
    fi

    # Remove generated gRPC/proto files
    if [ -d "$base_dir/proto" ]; then
        rm -f "$base_dir/proto/"*_pb2*.py
        rm -f "$base_dir/proto/__init__.py"
        log_success "Cleaned compiled proto stubs from $base_dir/proto."
    fi
}

# --- Phase 1.5: Virtual Interfaces & Networks Cleanup ---
clean_virtual_interfaces() {
    log_info "Phase 1.5: Cleaning up virtual network interfaces..."

    # Prune unused Docker networks if Docker is running
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        log_info "Pruning unused Docker networks..."
        docker network prune -f 2>/dev/null || true
    fi

    # Detect and remove orphaned virtual interface bridges and veth pairs
    local v_ifaces
    v_ifaces=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(veth|br-|cni|dummy|virbr)')

    if [ -n "$v_ifaces" ]; then
        log_warn "Found leftover virtual interfaces: $v_ifaces"
        if ask_user "Do you want to delete these virtual interfaces?" "Y"; then
            for iface in $v_ifaces; do
                log_info "Deleting interface $iface..."
                sudo ip link set "$iface" down 2>/dev/null || true
                sudo ip link delete "$iface" 2>/dev/null || true
            done
            log_success "Virtual network interfaces removed."
        fi
    else
        log_success "No orphaned virtual network interfaces found."
    fi
}

# --- Phase 2: Helm Repositories & Tooling ---
uninstall_helm_and_repos() {
    log_info "Phase 2: Cleaning up Helm repositories and binaries..."

    if command -v helm >/dev/null 2>&1; then
        helm repo remove onosproject 2>/dev/null || true
        helm repo remove towards5gs 2>/dev/null || true
        log_success "Removed ONOS and Towards5GS Helm repositories."
    fi

    if ask_user "Do you want to remove installed binaries (kubectl, grpcurl, helm) from /usr/local/bin?" "N"; then
        sudo rm -f /usr/local/bin/kubectl
        sudo rm -f /usr/local/bin/grpcurl
        sudo rm -f /usr/local/bin/helm
        log_success "Removed kubectl, grpcurl, and helm binaries."
    fi
}

# --- Phase 3: Protocol Buffers & Development Tools ---
uninstall_grpc_tools() {
    log_info "Phase 3: Reversing gRPC/protobuf tools..."

    if ask_user "Do you want to purge protobuf-compiler?" "N"; then
        sudo apt-get purge -y protobuf-compiler || true
        sudo apt-get autoremove -y
        log_success "Purged protobuf-compiler."
    fi
}

# --- Phase 4: Docker Uninstallation (Optional) ---
uninstall_docker() {
    log_info "Phase 4: Docker environment check..."

    if ask_user "Do you want to uninstall Docker completely from this machine?" "N"; then
        log_warn "Uninstalling Docker engine..."
        sudo apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker.io || true
        sudo rm -rf /var/lib/docker
        sudo rm -rf /var/lib/containerd
        log_success "Docker uninstalled."
    else
        log_info "Skipping Docker uninstallation."
    fi
}

# --- Phase 5: System APT Packages Clean-up ---
uninstall_sys_deps() {
    log_info "Phase 5: Cleaning up system packages..."

    if ask_user "Do you want to purge extra build dependencies installed by bootstrap (jq, python3-venv, python3-pip, build-essential)?" "N"; then
        sudo apt-get purge -y jq python3-venv python3-pip build-essential || true
        sudo apt-get autoremove -y
        log_success "System build dependencies removed."
    else
        log_info "Skipping APT package purge."
    fi
}

# --- Phase 6: OSM Installer & Temporary Script Cleanup ---
clean_temp_scripts() {
    log_info "Phase 6: Removing temporary downloads and installers..."

    rm -f get-docker.sh get_helm.sh install_osm.sh grpcurl_*.tar.gz LICENSE
    log_success "Temporary installer files removed."
}

# --- Phase 7: Repository Scaffolding & Workspace Wipe ---
clean_repo_structure() {
    log_info "Phase 7: Cleaning local repository directory..."
    local base_dir="."

    if ask_user "Do you want to completely clean non-tracked directory structure and scaffolding?" "Y"; then
        if [ -d ".git" ]; then
            log_info "Git repository detected. Executing git clean..."
            git clean -fdx
            git reset --hard HEAD
            log_success "Repository completely restored to clean Git state."
        else
            log_info "Removing scaffolded folder structure..."
            rm -rf "$base_dir"/.github \
                   "$base_dir"/docs \
                   "$base_dir"/deploy \
                   "$base_dir"/sdn-controller \
                   "$base_dir"/orchestration \
                   "$base_dir"/workloads \
                   "$base_dir"/hardware-agents \
                   "$base_dir"/tests \
                   "$base_dir"/scripts \
                   "$base_dir"/proto

            rm -f "$base_dir/README.md" "$base_dir/LICENSE" "$base_dir/Makefile"
            log_success "Scaffolded folder structure removed."
        fi
    else
        log_info "Skipped folder repository wipe."
    fi
}

# --- Main Execution ---
uninstall_python_env
clean_virtual_interfaces
uninstall_helm_and_repos
uninstall_grpc_tools
uninstall_docker
uninstall_sys_deps
clean_temp_scripts
clean_repo_structure

echo -e "${GREEN}====================================================${NC}"
echo -e "${GREEN} Teardown and Cleanup Complete! ${NC}"
echo -e "${GREEN}====================================================${NC}"