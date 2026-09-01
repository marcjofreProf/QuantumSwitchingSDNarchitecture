#!/bin/bash
# ---------------------------------------------------------------------------
# Quantum-SDN Switching Architecture Teardown Script
# ---------------------------------------------------------------------------

set -e

# --- Colors for Output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${CYAN}[INFO] $1${NC}"; }
log_success() { echo -e "${GREEN}[SUCCESS] $1${NC}"; }
log_warn() { echo -e "${YELLOW}[WARNING] $1${NC}"; }

log_info "Starting Quantum-SDN Architecture environment cleanup..."

# 1. Uninstall Helm Deployments
log_info "Uninstalling Helm releases..."
helm uninstall open5gs -n open5gs 2>/dev/null || true
helm uninstall onos-topo onos-config onos-operator -n micro-onos 2>/dev/null || true
helm uninstall atomix-controller atomix-raft-storage -n kube-system 2>/dev/null || true

# 2. Destroy Juju Controllers and Models
if command -v juju >/dev/null 2>&1; then
    log_info "Destroying Juju models and controllers..."
    juju destroy-model osm -y --destroy-storage --force 2>/dev/null || true
    juju kill-controller osm-vca -y 2>/dev/null || true
    rm -rf ~/.local/share/juju ~/.cache/juju 2>/dev/null || true
fi

# 3. Purge Kubernetes Namespaces and Manual Pods
log_info "Removing Kubernetes namespaces and pods..."
kubectl delete pod onos-config -n micro-onos --force --grace-period=0 2>/dev/null || true
kubectl delete pod onos-topo -n micro-onos --force --grace-period=0 2>/dev/null || true
kubectl delete namespace open5gs --force --grace-period=0 2>/dev/null || true
kubectl delete namespace micro-onos --force --grace-period=0 2>/dev/null || true
kubectl delete namespace osm --force --grace-period=0 2>/dev/null || true
kubectl delete namespace controller-osm-vca --force --grace-period=0 2>/dev/null || true

# 4. Cleanup Local Docker Images
if command -v docker >/dev/null 2>&1; then
    log_info "Removing built Docker images..."
    docker rmi quantum-restconf-gateway:1.0.0 2>/dev/null || true
    docker rmi onosproject/controller-quantum-switching:1.0.0-controller-quantum-switching-1.0.0 2>/dev/null || true
fi

# 5. Remove Virtual Environment
log_info "Removing Python Virtual Environment..."
sudo rm -rf /opt/sdn-venv

# 6. Delete Dynamically Generated Repository Files
log_info "Cleaning generated build artifacts, stubs, and model plugins..."
base_dir="."

# Clean Protobuf stubs
rm -f "$base_dir"/proto/*_pb2*.py "$base_dir"/proto/*.pyi "$base_dir"/proto/__init__.py 2>/dev/null || true

# Clean Python caches and environments
rm -rf "$base_dir"/.venv "$base_dir"/venv "$base_dir"/env 2>/dev/null || true
find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find . -type f \( -name "*.pyc" -o -name "*.pyo" -o -name "*.pyd" \) -delete 2>/dev/null || true

# Clean µONOS Model Plugin artifacts
plugin_dir="$base_dir/sdn-controller/northbound-interfaces/model-plugin"
rm -f "$plugin_dir"/VERSION "$plugin_dir"/metadata.yaml "$plugin_dir"/Makefile "$plugin_dir"/go.mod "$plugin_dir"/go.sum 2>/dev/null || true
rm -f "$plugin_dir"/yang/controller-quantum-switching.yang 2>/dev/null || true
rm -rf "$plugin_dir"/build "$plugin_dir"/proto 2>/dev/null || true
rm -f "$plugin_dir"/*.go 2>/dev/null || true

# Clean temporary installer downloads
rm -f get-docker.sh get_helm.sh install_osm.sh grpcurl_*.tar.gz helm-*-linux-amd64.tar.gz 2>/dev/null || true

# 7. Remove Custom Kernel & Network Configurations
log_info "Reverting custom sysctl configurations..."
sudo rm -f /etc/sysctl.d/99-sdn-uonos.conf /etc/sysctl.d/99-inotify-limits.conf /etc/sysctl.d/99-juju.conf /etc/modules-load.d/sdn-uonos.conf 2>/dev/null || true

log_success "Environment successfully cleaned up and reset!"
sdn-controller/northbound-interfaces/model-plugin/go.mod
sdn-controller/northbound-interfaces/model-plugin/go.sum
sdn-controller/northbound-interfaces/model-plugin/*.go
sdn-controller/northbound-interfaces/model-plugin/proto/
