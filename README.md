# QuantumSwitchingSDNarchitecture
Project to develop the quantum network infrastructure for SDN switching

This project works in tandem with the data plane repository: [QuantumNodeSwitchingSDNoperation](https://github.com/marcjofreProf/QuantumNodeSwitchingSDNoperation.git), which houses the nodes deployments for switching; and the operations and service repository: [QuantumServiceOperationSDNarchitecture](https://github.com/marcjofreProf/QuantumServiceOperationSDNarchitecture.git), which supports operations and services for users.

```text
quantum-sdn-architecture/
├── .github/workflows/          # CI/CD pipelines (linting, container builds)
├── deploy/                     # Infrastructure as Code (IaC) for 6G-OpenLab
│   ├── k8s-cluster/            # Kubernetes bootstrapping scripts/manifests
│   └── vm-provisioning/        # Terraform/Ansible for the µONOS VM
├── docs/                       # Architecture schematics, PDFs, and API references
├── hardware-agents/            # Device-level execution and translation
│   ├── gnoi-targets/           # Lightweight gNOI server stubs for physical switches
│   ├── netconf-servers/        # NETCONF server stubs for standardized switch management
│   └── switch-drivers/         # Vendor API scripts
├── inventory/                  # Quantum device target declarations & auto-registration
│   ├── devices/                # YAML definition files for simulators and switches
│   └── register-devices.sh     # Registration runner targeting onos-topo
├── orchestration/              # Open Source MANO (OSM) integration
│   ├── osm-packages/           # Network Service (NS) and CNF descriptors
│   └── yang-models/            # Standardized YANG models for orchestration
├── sdn-controller/             # µONOS deployment and custom microservices
│   ├── apps/                   # Custom µONOS apps for optical/quantum circuit pathing
│   ├── northbound-interfaces/  # gNMI streaming telemetry and RESTCONF endpoints
│   └── southbound-plugins/     # gNOI, gRPC, and NETCONF adapter implementations
├── scripts/                    # Developer utility scripts (setup, dummy traffic)
├── tests/                      # Validation and benchmarking
│   ├── e2e-path-provisioning/  # End-to-end tests for Port A to Port B mapping
│   └── latency-benchmarks/     # Control-plane to data-plane sub-millisecond tests
├── workloads/                  # 5G/6G containerized network functions
│   └── open5gs/                # Helm charts/Kustomize files for Open5GS pods
└── bootstrap-quantum-switching-sdn.sh
└── uninstall-bootstrap-quantum-switching-sdn.sh
```

# Quantum switching SDN Architecture

An ultra-low latency, pure circuit-switched Software Defined Networking (SDN) architecture designed for quantum data planes. 

Because packet inspection cannot be performed on a single photon without destroying its quantum state, traditional header-parsing pipelines (like P4) are unusable. This architecture relies on a **microONOS (µONOS)** control plane paired with **gNOI over gRPC** and **NETCONF** to bypass heavy datastore commits and XML parsing, achieving the sub-millisecond execution speeds required for dynamic quantum path provisioning.

Designed for deployment on the **6G-OpenLab** infrastructure.

---

## Device Inventory & Topology Registration
The architecture decouples device management from the controller deployment pipeline. Network nodes (both virtual simulators and physical switches) are declared declaratively as YAML manifests in the inventory/devices/ directory.

Concept & Architecture
Declarative Definitions: Every node (devicesim-1, quantum-node-1, etc.) is defined in inventory/devices/<node-id>.yaml.

Automated Provisioning: The ./inventory/register-devices.sh script parses the YAML manifests and injects target endpoints directly into the µONOS topology service (onos-topo) via gnmic.

Adding a New Quantum Device
To onboard a new physical switch or virtual target into the control plane:

1. Create a YAML definition file inside inventory/devices/ (e.g., inventory/devices/quantum-node-2.yaml):
```text
id: "quantum-node-2"
display_name: "Physical Quantum Switch 2"
address: "10.0.0.253:9339"
kind: "beaglebone-qswitch"
role: "quantum-switch"
protocols:
  - name: "gnoi"
    port: 9339
  - name: "netconf"
    port: 830
```

2. Execute the registration runner:
```bash
./inventory/register-devices.sh
```

3. Verify Registration:
Query onos-topo directly using gnmic to ensure the device is active in the controller topology:
```bash
gnmic -a localhost:30150 --skip-verify get --path /interfaces/interface
```

## Quickstart: Environment Bootstrap

To quickly set up the repository structure and install all necessary cloud-native dependencies (Docker, Kubernetes/Kind, Helm, Protoc, µONOS, Open5GS, and optionally OSM), use the provided bootstrap script.

**1. Clone the repository and navigate into it:**
git clone https://github.com/marcjofreProf/QuantumSwitchingSDNarchitecture.git
cd QuantumSwitchingSDNarchitecture

sudo chmod +x ./bootstrap-quantum-switching-sdn.sh
./bootstrap-quantum-switching-sdn.sh

If the centralized server lacks the RAM/CPU to run a full Kubernetes cluster and µONOS, it can bypass the SDN controller layer for testing or lightweight deployments.

## Recovery after abrupt stop:

To recover the different elements after and abrupt stop and re-start:

```bash
# 1. Scale down to 0 to kill duplicate rolling pods
kubectl scale deployment -n micro-onos onos-config onos-topo onos-umbrella-device-provisioner --replicas=0

# 2. Patch finalizers and force delete stuck PVCs and pods
for pvc in $(kubectl get pvc -n micro-onos --no-headers -o custom-columns=":metadata.name" | grep consensus); do
  kubectl patch pvc $pvc -n micro-onos -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
done

for pod in $(kubectl get pods -n micro-onos --no-headers -o custom-columns=":metadata.name" | grep -E "consensus|onos-config|onos-topo|device-provisioner"); do
  kubectl patch pod $pod -n micro-onos -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
  kubectl delete pod $pod -n micro-onos --force --grace-period=0 2>/dev/null || true
done

# 3. Restart K3s engine and wait for API server recovery
sudo systemctl restart k3s
echo "Waiting for K3s API server to come back online..."
until kubectl get nodes >/dev/null 2>&1; do sleep 3; done

# 4. Scale back to 1 replica and apply environment settings
kubectl scale deployment -n micro-onos onos-config onos-topo onos-umbrella-device-provisioner --replicas=1
kubectl set env deployment/onos-config -n micro-onos MASTER_ELECTION=false 2>/dev/null || true[cite: 1]

# 5. Clear lingering transaction locks
sleep 5
for tx in $(kubectl exec -n micro-onos deployment/onos-cli -- onos config get transactions 2>/dev/null | awk 'NR>1 {print $1}'); do
  kubectl exec -n micro-onos deployment/onos-cli -- onos config delete transaction "$tx" 2>/dev/null || true[cite: 1]
done
kubectl get pods -n micro-onos -w
```
Then, re-register the devices in the micro-onos:
```bash
kubectl rollout restart deployment -n micro-onos onos-topo
kubectl rollout status deployment -n micro-onos onos-topo --timeout=60s
kubectl rollout restart deployment -n micro-onos onos-config
kubectl rollout status deployment -n micro-onos onos-config --timeout=60s
./inventory/register-devices.sh
```

## Hardware Debugging Tools

In the full architecture, a central SDN Controller (like µONOS) will manage the network topology and send commands to the switches automatically. 

However, during initial deployment or hardware troubleshooting, you can bypass the SDN controller and issue gRPC commands directly to individual hardware nodes using the provided developer scripts.

**Note:** Ensure you have run the bootstrap script first, as it compiles the necessary gRPC stubs from the `proto/` directory.

### Manual Node Control
Use the CLI client to test individual connections to a node using its IP address.

```bash
## Check gNOI
# Check if the hardware node is connected or disconnected
python3 ./hardware-agents/switch-drivers/gnoi-switching-client.py <NODE_IP> status

# Force the physical switch to connect (cross-connect)
python3 ./hardware-agents/switch-drivers/gnoi-switching-client.py <NODE_IP> connect

# Force the physical switch to disconnect
python3 ./hardware-agents/switch-drivers/gnoi-switching-client.py <NODE_IP> disconnect

## Check gNMI
# Check if the hardware node is connected or disconnected
python3 ./hardware-agents/switch-drivers/gnmif-switching-client.py <NODE_IP> status

# Force the physical switch to connect (cross-connect)
python3 ./hardware-agents/switch-drivers/gnmi-switching-client.py <NODE_IP> connect

# Force the physical switch to disconnect
python3 ./hardware-agents/switch-drivers/gnmi-switching-client.py <NODE_IP> disconnect

## Check NETCONF
# Check if the hardware node is connected or disconnected
python3 ./hardware-agents/switch-drivers/netconf-switching-client.py <NODE_IP> status

# Force the physical switch to connect (cross-connect)
python3 ./hardware-agents/switch-drivers/netconf-switching-client.py <NODE_IP> connect

# Force the physical switch to disconnect
python3 ./hardware-agents/switch-drivers/netconf-switching-client.py <NODE_IP> disconnect
```

## Northbound Interface Tests
These end-to-end tests verify service provisioning across the SDN controller northbound interfaces:
 - test-gnmi-northbound.sh: Validates direct gNMI/gRPC operations (Capabilities, Set, Get) against onos-config: ./tests/e2e-path-provisioning/test-gnmi-northbound.sh
 - test-restconf-northbound.py: Validates HTTP RESTCONF operations (POST, GET) against restconf-gateway: /opt/sdn-venv/bin/python3 ./tests/e2e-path-provisioning/test-restconf-northbound.py

## Environment Teardown & Cleanup

To remove installed binaries, purge the Python virtual environment and compiled stubs, delete Helm repositories, and reset the workspace to a clean Git state, run the provided teardown script:

```bash
sudo chmod +x uninstall-bootstrap-quantum-switching-sdn.sh
./uninstall-bootstrap-quantum-switching-sdn.sh
```

## Lessons-Learned
# µONOS gNMI Access

## Northbound gNMI (onos-config:5150)

- Protocol: gRPC over mTLS
- Client certs: `tls.crt` + `tls.key` (shipped in the onos-cli image)
- CA: `onfca.crt` (ONF root CA)
- Server cert verification: **must be skipped** because the server cert
  is signed by a CA that isn't distributed to the client.
  Use `--skip-verify` in gnmic.
- Do NOT use `tls.cacrt` from the onos-config-secret as a CA — it is
  a leaf certificate, not a CA, and gnmic will reject it.

# Example (from operation terminal to controller)

    gnmic -a <onos-config-LB-IP>:5150 \
      --tls-cert /etc/onos/certs/tls.crt \
      --tls-key  /etc/onos/certs/tls.key \
      --skip-verify \
      capabilities

## Southbound gNMI (BeagleBone device, e.g. quantum-node-1)

The southbound direction is the opposite of the northbound one: here `onos-config` is the **client** and the node device is the **server**.
The connection parameters live in the topology entity's `onos.topo.Configurable` and `onos.topo.TLSOptions` aspects — not in any cert files you pass on the command line.

- Protocol: gRPC, **plaintext** (no TLS)
- Server endpoint: `<device-node-IP>:50051`
- Client certs: **none** — the device does not require or accept mTLS
- CA: **none** — plaintext, so there is nothing to verify
- Server cert verification: **not applicable** — plaintext
- Required topology aspects on the `quantum-node-1` entity:
  - `onos.topo.Configurable={"address":"<device-node-IP>:50051","type":"devicesim","version":"1.0.x"}`
  - `onos.topo.TLSOptions={"plain":true,"insecure":true}`

`plain: true` tells `onos-config` to skip TLS entirely on this target.
`insecure: true` is redundant when `plain: true` but is harmless and matches what the ONF charts emit by default.

# Example (from operator terminal to device, bypassing onos-config)

To probe the BeagleBone's own gNMI server directly:

    gnmic -a 10.0.0.254:50051 \
      --insecure \
      capabilities

Note that `--insecure` here means **plaintext gRPC** in gnmic — no TLS handshake at all. This is the correct flag for a plaintext gNMI
endpoint. Do **not** pass `--tls-cert`, `--tls-key`, or `--tls-ca` to a plaintext endpoint.

## What the current setup does NOT do

The BeagleBone's gNMI server is reachable and responds to `Capabilities`,
but `Set` operations still fail with `not yet supported` because:

- `onos-config` validates every write path against the **model plugin**
  registered for the target's `type` field.
- `quantum-node-1` is registered as `type: devicesim`, so `onos-config`
  loads the `devicesim` model plugin.
- The `devicesim` plugin only implements a small subset of the
  OpenConfig writable paths, and it does **not** know your BeagleBone's
  actual schema.

To make `Set` operations succeed against the BeagleBone you must:

1. Write a YANG model describing the BeagleBone's real configuration surface.
2. Build a custom model plugin from that YANG model (`CGO_ENABLED=1 go build -buildmode=plugin ...`).
3. Load the plugin into `onos-config`.
4. Re-register `quantum-node-1` in `onos-topo` with `type: <your-custom-type>` and `version: <model-revision>`, so `onos-config` picks up the new plugin for that target.

Until step 4 is done, only paths supported by `devicesim` will validate, and in practice that means almost nothing is writable.


## Writable paths

The `devicesim` model plugin implements only a very small subset of OpenConfig writes. Attempts to write to `/system/config/motd-banner`
or `/system/clock/config/timezone-name` return `not yet supported`. For custom writable paths, build a proper model plugin (see `sdn-controller/northbound-interfaces/model-plugin`).
