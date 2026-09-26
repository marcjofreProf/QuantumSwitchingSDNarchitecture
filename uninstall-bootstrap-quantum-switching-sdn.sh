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

# Dismantle SDN Adapter + RESTCONF Gateway workloads from their manifests
log_info "Dismantling SDN Adapter and RESTCONF Gateway..."
kubectl delete -f sdn-controller/southbound-plugins/sdn-adapter/deploy.yaml \
    --ignore-not-found=true 2>/dev/null || true
kubectl delete -f sdn-controller/northbound-interfaces/restconf-gateway/deploy.yaml \
    --ignore-not-found=true 2>/dev/null || true

# Belt-and-braces: catch anything created before the manifests existed
kubectl delete service    sdn-adapter -n micro-onos --ignore-not-found=true 2>/dev/null || true
kubectl delete deployment sdn-adapter -n micro-onos --ignore-not-found=true 2>/dev/null || true
kubectl delete pod        sdn-adapter -n micro-onos --force --grace-period=0 2>/dev/null || true

kubectl delete service    restconf-gateway -n micro-onos --ignore-not-found=true 2>/dev/null || true
kubectl delete deployment restconf-gateway -n micro-onos --ignore-not-found=true 2>/dev/null || true

# 2. Uninstall Helm Deployments
log_info "Uninstalling Helm releases..."
helm uninstall open5gs -n open5gs 2>/dev/null || true
helm uninstall onos-topo onos-config -n micro-onos 2>/dev/null || true
helm uninstall onos-operator atomix atomix-controller atomix-raft-storage -n kube-system 2>/dev/null || true
kubectl delete serviceaccount atomix-controller onos-operator -n kube-system 2>/dev/null || true

# 3. Destroy Juju Controllers and Models
if command -v juju >/dev/null 2>&1; then
    log_info "Destroying Juju models and controllers..."
    juju destroy-model osm -y --destroy-storage --force 2>/dev/null || true
    juju kill-controller osm-vca -y --timeout 30s 2>/dev/null || true
    rm -rf ~/.local/share/juju ~/.cache/juju 2>/dev/null || true
    log_success "Juju models and controllers purged."
fi

# 4. Purge Cluster-Scoped Resources (Webhooks, RBAC, CRDs)
log_info "Purging cluster-scoped Webhook Configurations, ClusterRoles, and CRDs..."

# Remove Mutating & Validating Webhooks (Atomix, ONOS, Juju, OSM)
# Redirect both stdout and stderr: `kubectl delete -l <selector>` prints
# "No resources found" to stdout when the selector matches nothing.
kubectl delete mutatingwebhookconfigurations -l app.kubernetes.io/part-of=atomix >/dev/null 2>&1 || true
kubectl delete mutatingwebhookconfigurations -l controller.juju.is/name=osm-vca >/dev/null 2>&1 || true
kubectl delete validatingwebhookconfigurations -l controller.juju.is/name=osm-vca >/dev/null 2>&1 || true

for mwc in $(kubectl get mutatingwebhookconfigurations -o name 2>/dev/null | grep -E 'atomix|onos|juju|osm'); do
    echo -e "${CYAN}Deleting mutating webhook: ${mwc}${NC}"
    kubectl delete "$mwc" 2>/dev/null || true
done
for vwc in $(kubectl get validatingwebhookconfigurations -o name 2>/dev/null | grep -E 'atomix|onos|juju|osm'); do
    echo -e "${CYAN}Deleting validating webhook: ${vwc}${NC}"
    kubectl delete "$vwc" 2>/dev/null || true
done

# Remove ClusterRoles and ClusterRoleBindings
kubectl delete clusterrolebindings -l controller.juju.is/name=osm-vca >/dev/null 2>&1 || true
kubectl delete clusterroles       -l controller.juju.is/name=osm-vca >/dev/null 2>&1 || true
kubectl delete clusterrolebindings -l app.kubernetes.io/part-of=atomix >/dev/null 2>&1 || true
kubectl delete clusterroles       -l app.kubernetes.io/part-of=atomix >/dev/null 2>&1 || true
kubectl delete clusterrolebindings -l app.kubernetes.io/name=onos-operator >/dev/null 2>&1 || true
kubectl delete clusterroles       -l app.kubernetes.io/name=onos-operator >/dev/null 2>&1 || true

# Remove leftover Custom Resource Definitions (CRDs)
for crd in $(kubectl get crd -o name 2>/dev/null | grep -E 'atomix.io|onosproject.org|juju'); do
    echo -e "${CYAN}Deleting CRD: ${crd}${NC}"
    kubectl delete "$crd" 2>/dev/null || true
done

# 5. Purge µONOS Kubernetes resources
log_info "Removing µONOS workloads, namespaces and CRDs..."

if helm status onos-umbrella -n micro-onos >/dev/null 2>&1; then
    log_info "Uninstalling onos-umbrella..."
    helm uninstall onos-umbrella -n micro-onos 2>/dev/null || true
fi

if kubectl get namespace micro-onos >/dev/null 2>&1; then
    log_info "Deleting micro-onos namespace..."
    kubectl delete namespace micro-onos --wait=true 2>/dev/null || true
fi

if helm status atomix -n kube-system >/dev/null 2>&1; then
    log_info "Uninstalling Atomix..."
    helm uninstall atomix -n kube-system 2>/dev/null || true
fi

log_info "Removing Atomix custom resources..."
kubectl delete storageprofiles.atomix.io --all --all-namespaces --ignore-not-found=true 2>/dev/null || true
kubectl delete raftclusters.raft.atomix.io --all --all-namespaces --ignore-not-found=true 2>/dev/null || true
kubectl delete raftstores.raft.atomix.io --all --all-namespaces --ignore-not-found=true 2>/dev/null || true

log_info "Removing Atomix CRDs..."
kubectl get crd -o name 2>/dev/null \
    | grep -E '(^|\.)(atomix\.io|raft\.atomix\.io)$' \
    | xargs -r kubectl delete 2>/dev/null || true

kubectl delete crd \
    storageprofiles.atomix.io \
    raftclusters.raft.atomix.io \
    raftstores.raft.atomix.io \
    --ignore-not-found=true 2>/dev/null || true

log_info "Removing remaining Atomix/ONOS operator workloads..."
kubectl get pods -n kube-system -o name 2>/dev/null \
    | grep -E 'atomix|onos-operator' \
    | xargs -r kubectl delete -n kube-system \
        --force --grace-period=0 2>/dev/null || true

kubectl get deployments -n kube-system -o name 2>/dev/null \
    | grep -E 'atomix|onos-operator' \
    | xargs -r kubectl delete -n kube-system 2>/dev/null || true

kubectl get clusterrole -o name 2>/dev/null \
    | grep -E 'atomix|onos-operator' \
    | xargs -r kubectl delete 2>/dev/null || true

kubectl get clusterrolebinding -o name 2>/dev/null \
    | grep -E 'atomix|onos-operator' \
    | xargs -r kubectl delete 2>/dev/null || true

log_info "µONOS Kubernetes cleanup completed."

log_info "Purging remaining SDN and orchestration namespaces..."
kubectl delete namespace open5gs --force --grace-period=0 2>/dev/null || true
kubectl delete namespace micro-onos --force --grace-period=0 2>/dev/null || true
kubectl delete namespace osm --force --grace-period=0 2>/dev/null || true
kubectl delete namespace controller-osm-vca --force --grace-period=0 2>/dev/null || true

# 6. Cleanup Local Docker Images
#
# Every tag is swept, not just 1.0.0. During development you accumulate
# many tags (1.0.0, 2.0.0, 2.0.1, 2.1.0, ...), and hardcoding one tag
# leaves the rest behind. Three image families are handled:
#   - sdn-adapter:*                                 (southbound adapter)
#   - quantum-restconf-gateway:*                    (northbound gateway)
#   - onosproject/controller-quantum-switching:*    (model plugin)
if command -v docker >/dev/null 2>&1; then
    log_info "Removing built Docker images..."
    for img in $(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
            | grep -E '^(sdn-adapter|quantum-restconf-gateway|onosproject/controller-quantum-switching):'); do
        log_info "  Removing image $img"
        docker rmi "$img" 2>/dev/null || true
    done
    log_success "Docker images cleaned up."
fi

# Remove built images from K3s containerd.
#
# Same reasoning as the Docker cleanup above: sweep every tag, not just
# 1.0.0. The model plugin is imported into containerd too by the bootstrap
# (via `sudo k3s ctr images import -`), so it belongs in this sweep.
# k3s ctr uses the fully-qualified reference, e.g.
#   docker.io/library/sdn-adapter:2.1.0
#   docker.io/onosproject/controller-quantum-switching:1.0.0-controller-quantum-switching-1.0.0
# so the grep matches on the suffix (image name) rather than the prefix.
if command -v k3s >/dev/null 2>&1; then
    log_info "Removing K3s containerd images..."
    for img in $(sudo k3s ctr images ls -q 2>/dev/null \
            | grep -E 'sdn-adapter:|quantum-restconf-gateway:|controller-quantum-switching:'); do
        log_info "  Removing containerd image $img"
        sudo k3s ctr images rm "$img" 2>/dev/null || true
    done
    log_success "K3s containerd images cleaned up."
fi

# 7. Remove Virtual Environment
log_info "Removing Python Virtual Environments..."
sudo rm -rf /opt/sdn-venv 2>/dev/null || true
rm -rf "$base_dir"/.venv "$base_dir"/venv "$base_dir"/env 2>/dev/null || true

# 7b. Remove extracted µONOS certs, gnmic configuration, and deployment config
log_info "Removing extracted µONOS certs, gnmic configuration, and deployment config..."
sudo rm -rf /etc/onos/certs 2>/dev/null || true
sudo rm -f  /etc/gnmic/gnmic.yaml 2>/dev/null || true
sudo rmdir  /etc/gnmic 2>/dev/null || true
rm -f ./.gnmic.yaml 2>/dev/null || true
rm -f "${HOME}/.gnmic.yaml" 2>/dev/null || true

# Remove the deployment config so the next bootstrap re-prompts.
# Comment this line out if you want the values to survive a teardown.
rm -rf "${HOME}/.quantum-sdn" 2>/dev/null || true
log_success "Certificate, gnmic and deployment configuration removed."

# 8. Delete Dynamically Generated Repository Files
log_info "Cleaning generated build artifacts, stubs, and model plugins..."
base_dir="."

# Remove generated Python stubs (both flat and nested layouts)
find "$base_dir/proto" -type f \
    \( -name "*_pb2*.py" -o -name "*.pyi" -o -name "__init__.py" \) \
    -delete 2>/dev/null || true

# Remove only the *downloaded* proto sources. Do NOT delete tracked
# source files like proto/quantum_gnoi_switching.proto or
# inventory/gnmi_set_with_ext.py — those live in git and must survive.
rm -f  "$base_dir/proto/gnmi.proto"    2>/dev/null || true
rm -f  "$base_dir/proto/gnmi_ext.proto" 2>/dev/null || true
rm -rf "$base_dir/proto/github.com"    2>/dev/null || true
rm -rf "$base_dir/proto/github"        2>/dev/null || true

# Purge virtual environments and Python cache
rm -rf "$base_dir"/.venv "$base_dir"/venv "$base_dir"/env 2>/dev/null || true
find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find . -type f \( -name "*.pyc" -o -name "*.pyo" -o -name "*.pyd" \) -delete 2>/dev/null || true

plugin_dir="$base_dir/sdn-controller/northbound-interfaces/model-plugin"

# Generated by model-compiler
rm -f  "$plugin_dir"/VERSION "$plugin_dir"/Makefile "$plugin_dir"/go.mod "$plugin_dir"/go.sum 2>/dev/null || true
rm -f  "$plugin_dir"/Dockerfile 2>/dev/null || true
rm -f  "$plugin_dir"/*.go 2>/dev/null || true
rm -f  "$plugin_dir"/*.tree 2>/dev/null || true
rm -rf "$plugin_dir"/build "$plugin_dir"/proto 2>/dev/null || true
rm -rf "$plugin_dir"/api "$plugin_dir"/openapi "$plugin_dir"/plugin 2>/dev/null || true
rm -rf "$plugin_dir"/vendor 2>/dev/null || true

# Copied from the tracked YANG source
rm -rf "$plugin_dir"/yang 2>/dev/null || true

# DO NOT remove:
#   controller-quantum-switching-model.yaml  (tracked source)
#   metadata.yaml                            (may be tracked depending on workflow)

rm -f get-docker.sh get_helm.sh install_osm.sh grpcurl_*.tar.gz helm-*-linux-amd64.tar.gz 2>/dev/null || true

# 9. Remove Custom Kernel & Network Configurations
log_info "Reverting custom sysctl configurations..."
sudo rm -f /etc/sysctl.d/99-sdn-uonos.conf /etc/sysctl.d/99-inotify-limits.conf /etc/sysctl.d/99-juju.conf /etc/modules-load.d/sdn-uonos.conf 2>/dev/null || true

log_success "Environment successfully cleaned up and reset!"
