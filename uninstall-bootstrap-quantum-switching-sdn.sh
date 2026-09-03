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
helm uninstall onos-topo onos-config -n micro-onos 2>/dev/null || true
helm uninstall onos-operator atomix atomix-controller atomix-raft-storage -n kube-system 2>/dev/null || true
kubectl delete serviceaccount atomix-controller onos-operator -n kube-system 2>/dev/null || true

# 2. Destroy Juju Controllers and Models
if command -v juju >/dev/null 2>&1; then
    log_info "Destroying Juju models and controllers..."
    juju destroy-model osm -y --destroy-storage --force 2>/dev/null || true
    juju kill-controller osm-vca -y --timeout 30s 2>/dev/null || true
    rm -rf ~/.local/share/juju ~/.cache/juju 2>/dev/null || true
fi

# 3. Purge Cluster-Scoped Resources (Webhooks, RBAC, CRDs)
log_info "Purging cluster-scoped Webhook Configurations, ClusterRoles, and CRDs..."

# Remove Mutating & Validating Webhooks (Atomix, ONOS, Juju, OSM)
kubectl delete mutatingwebhookconfigurations -l app.kubernetes.io/part-of=atomix 2>/dev/null || true
kubectl delete mutatingwebhookconfigurations -l controller.juju.is/name=osm-vca 2>/dev/null || true
kubectl delete validatingwebhookconfigurations -l controller.juju.is/name=osm-vca 2>/dev/null || true

for mwc in $(kubectl get mutatingwebhookconfigurations -o name 2>/dev/null | grep -E 'atomix|onos|juju|osm'); do
    kubectl delete "$mwc" 2>/dev/null || true
done
for vwc in $(kubectl get validatingwebhookconfigurations -o name 2>/dev/null | grep -E 'atomix|onos|juju|osm'); do
    kubectl delete "$vwc" 2>/dev/null || true
done

# Remove ClusterRoles and ClusterRoleBindings
kubectl delete clusterrolebindings -l controller.juju.is/name=osm-vca 2>/dev/null || true
kubectl delete clusterroles -l controller.juju.is/name=osm-vca 2>/dev/null || true
kubectl delete clusterrolebindings -l app.kubernetes.io/part-of=atomix 2>/dev/null || true
kubectl delete clusterroles -l app.kubernetes.io/part-of=atomix 2>/dev/null || true
kubectl delete clusterrolebindings -l app.kubernetes.io/name=onos-operator 2>/dev/null || true
kubectl delete clusterroles -l app.kubernetes.io/name=onos-operator 2>/dev/null || true

# Remove leftover Custom Resource Definitions (CRDs)
for crd in $(kubectl get crd -o name 2>/dev/null | grep -E 'atomix.io|onosproject.org|juju'); do
    kubectl delete "$crd" 2>/dev/null || true
done

# 4. Purge µONOS Kubernetes resources
log_info "Removing µONOS workloads, namespaces and CRDs..."

# ------------------------------------------------------------------
# Remove µONOS Helm release
# ------------------------------------------------------------------
if helm status onos-umbrella -n micro-onos >/dev/null 2>&1; then
    log_info "Uninstalling onos-umbrella..."
    helm uninstall onos-umbrella -n micro-onos 2>/dev/null || true
fi

# ------------------------------------------------------------------
# Remove µONOS namespace
# This removes pods, deployments, services, configmaps, secrets, etc.
# ------------------------------------------------------------------
if kubectl get namespace micro-onos >/dev/null 2>&1; then
    log_info "Deleting micro-onos namespace..."
    kubectl delete namespace micro-onos --wait=true 2>/dev/null || true
fi

# ------------------------------------------------------------------
# Remove Atomix Helm release
# ------------------------------------------------------------------
if helm status atomix -n kube-system >/dev/null 2>&1; then
    log_info "Uninstalling Atomix..."
    helm uninstall atomix -n kube-system 2>/dev/null || true
fi

# ------------------------------------------------------------------
# Remove Atomix custom resources
#
# These can survive Helm uninstallation because they are instances
# of CRDs rather than normal namespaced Kubernetes objects.
# ------------------------------------------------------------------
log_info "Removing Atomix custom resources..."

kubectl delete storageprofiles.atomix.io --all --all-namespaces \
    --ignore-not-found=true 2>/dev/null || true

kubectl delete raftclusters.raft.atomix.io --all --all-namespaces \
    --ignore-not-found=true 2>/dev/null || true

kubectl delete raftstores.raft.atomix.io --all --all-namespaces \
    --ignore-not-found=true 2>/dev/null || true

# ------------------------------------------------------------------
# Remove Atomix CRDs
#
# Required for a completely clean µONOS reinstall.
# ------------------------------------------------------------------
log_info "Removing Atomix CRDs..."

kubectl get crd -o name 2>/dev/null \
    | grep -E '(^|\.)(atomix\.io|raft\.atomix\.io)$' \
    | xargs -r kubectl delete 2>/dev/null || true

# More robust fallback: explicitly delete the CRDs used by µONOS.
kubectl delete crd \
    storageprofiles.atomix.io \
    raftclusters.raft.atomix.io \
    raftstores.raft.atomix.io \
    --ignore-not-found=true 2>/dev/null || true

# ------------------------------------------------------------------
# Remove any remaining Atomix / ONOS operator workloads
# ------------------------------------------------------------------
log_info "Removing remaining Atomix/ONOS operator workloads..."

kubectl get pods -n kube-system -o name 2>/dev/null \
    | grep -E 'atomix|onos-operator' \
    | xargs -r kubectl delete -n kube-system \
        --force --grace-period=0 2>/dev/null || true

kubectl get deployments -n kube-system -o name 2>/dev/null \
    | grep -E 'atomix|onos-operator' \
    | xargs -r kubectl delete -n kube-system 2>/dev/null || true

# ------------------------------------------------------------------
# Remove Atomix-related ClusterRoles / ClusterRoleBindings if they
# were left behind by the Helm release.
# ------------------------------------------------------------------
kubectl get clusterrole -o name 2>/dev/null \
    | grep -E 'atomix|onos-operator' \
    | xargs -r kubectl delete 2>/dev/null || true

kubectl get clusterrolebinding -o name 2>/dev/null \
    | grep -E 'atomix|onos-operator' \
    | xargs -r kubectl delete 2>/dev/null || true

log_info "µONOS Kubernetes cleanup completed."

kubectl delete namespace open5gs --force --grace-period=0 2>/dev/null || true
kubectl delete namespace micro-onos --force --grace-period=0 2>/dev/null || true
kubectl delete namespace osm --force --grace-period=0 2>/dev/null || true
kubectl delete namespace controller-osm-vca --force --grace-period=0 2>/dev/null || true

# 5. Cleanup Local Docker Images
if command -v docker >/dev/null 2>&1; then
    log_info "Removing built Docker images..."
    docker rmi quantum-restconf-gateway:1.0.0 2>/dev/null || true
    docker rmi onosproject/controller-quantum-switching:1.0.0-controller-quantum-switching-1.0.0 2>/dev/null || true
fi

# 6. Remove Virtual Environment
log_info "Removing Python Virtual Environment..."
sudo rm -rf /opt/sdn-venv

# 7. Delete Dynamically Generated Repository Files
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

# 8. Remove Custom Kernel & Network Configurations
log_info "Reverting custom sysctl configurations..."
sudo rm -f /etc/sysctl.d/99-sdn-uonos.conf /etc/sysctl.d/99-inotify-limits.conf /etc/sysctl.d/99-juju.conf /etc/modules-load.d/sdn-uonos.conf 2>/dev/null || true

log_success "Environment successfully cleaned up and reset!"
