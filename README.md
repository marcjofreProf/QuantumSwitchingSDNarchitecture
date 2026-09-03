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


# Quantum switching SDN Architecture

An ultra-low latency, pure circuit-switched Software Defined Networking (SDN) architecture designed for quantum data planes. 

Because packet inspection cannot be performed on a single photon without destroying its quantum state, traditional header-parsing pipelines (like P4) are unusable. This architecture relies on a **microONOS (µONOS)** control plane paired with **gNOI over gRPC** and **NETCONF** to bypass heavy datastore commits and XML parsing, achieving the sub-millisecond execution speeds required for dynamic quantum path provisioning.

Designed for deployment on the **6G-OpenLab** infrastructure.

---

## Quickstart: Environment Bootstrap

To quickly set up the repository structure and install all necessary cloud-native dependencies (Docker, Kubernetes/Kind, Helm, Protoc, µONOS, Open5GS, and optionally OSM), use the provided bootstrap script.

**1. Clone the repository and navigate into it:**
git clone https://github.com/marcjofreProf/QuantumSwitchingSDNarchitecture.git
cd QuantumSwitchingSDNarchitecture

sudo chmod +x ./bootstrap-quantum-switching-sdn.sh
./bootstrap-quantum-switching-sdn.sh

If the centralized server lacks the RAM/CPU to run a full Kubernetes cluster and µONOS, it can bypass the SDN controller layer for testing or lightweight deployments.

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

## Check NETCONF
# Check if the hardware node is connected or disconnected
python3 ./hardware-agents/switch-drivers/netconf-switching-client.py <NODE_IP> status

# Force the physical switch to connect (cross-connect)
python3 ./hardware-agents/switch-drivers/netconf-switching-client.py <NODE_IP> connect

# Force the physical switch to disconnect
python3 ./hardware-agents/switch-drivers/netconf-switching-client.py <NODE_IP> disconnect

## Northbound Interface Tests
These end-to-end tests verify service provisioning across the SDN controller northbound interfaces:
 - test-gnmi-northbound.sh: Validates direct gNMI/gRPC operations (Capabilities, Set, Get) against onos-config: ./tests/e2e-path-provisioning/test-gnmi-northbound.sh
 - test-restconf-northbound.py: Validates HTTP RESTCONF operations (POST, GET) against restconf-gateway: python3 ./tests/e2e-path-provisioning/test-restconf-northbound.py

## Environment Teardown & Cleanup

To remove installed binaries, purge the Python virtual environment and compiled stubs, delete Helm repositories, and reset the workspace to a clean Git state, run the provided teardown script:

```bash
sudo chmod +x uninstall-bootstrap-quantum-switching-sdn.sh
./uninstall-bootstrap-quantum-switching-sdn.sh
