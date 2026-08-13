# QuantumSwitchingSDNarchitecture
Project to develop the quantum network infrastructure for SDN switching

QuantumSwitchingSDNarchitecture/
├── .github/
│   └── workflows/              # CI/CD pipelines (e.g., linting YANG models, building agent containers)
├── docs/
│   ├── architecture/           # LaTeX source files, PDFs, and architecture schematics
│   └── api/                    # gRPC protobuf definitions and RESTCONF API documentation
├── deploy/                     # Infrastructure as Code (IaC) for 6G-OpenLab
│   ├── vm-provisioning/        # Terraform/Ansible for the µONOS VM in 6G-OpenLab
│   └── k8s-cluster/            # Kubernetes bootstrapping scripts/manifests
├── sdn-controller/             # µONOS deployment and custom microservices
│   ├── apps/                   # Custom µONOS apps for optical/quantum circuit pathing
│   ├── southbound-plugins/     # gNOI / gRPC adapter implementations
│   └── northbound-interfaces/  # gNMI streaming telemetry and RESTCONF endpoints
├── orchestration/              # Open Source MANO (OSM) integration
│   ├── osm-packages/           # Network Service (NS) and Cloud-Native (CNF) descriptors
│   └── yang-models/            # Standardized YANG models for seamless service orchestration
├── workloads/                  # 5G/6G containerized network functions
│   └── open5gs/                # Helm charts or Kustomize files for Open5GS pods
├── hardware-agents/            # Device-level execution and translation
│   ├── gnoi-targets/           # Lightweight gNOI server stubs to run on/near physical switches
│   └── switch-drivers/         # Vendor-specific API scripts (Agiltron, Thorlabs, Keysight, DiCon)
├── tests/                      # Validation and benchmarking
│   ├── latency-benchmarks/     # Scripts to measure control-plane to data-plane sub-millisecond execution
│   └── e2e-path-provisioning/  # End-to-end tests verifying Port A to Port B mapping
├── scripts/                    # Developer utility scripts (setup, teardown, dummy traffic generation)
├── README.md                   # Project overview and quickstart guide
├── LICENSE                     # Open source license
└── Makefile                    # Make targets for easy deployment (e.g., `make deploy-microonos`)
