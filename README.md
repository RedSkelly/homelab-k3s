# homelab-k3s

Production-patterned Kubernetes platform built on bare metal, designed to be torn down and rebuilt entirely from code. The value here is the deployment pipeline and operational patterns, not the workloads.

## Architecture

```
┌───────────────────────────────────────────────┐
│  OPNsense (bare metal, Lenovo M920Q)          │
│  Firewall / Router / WireGuard VPN / DNS      │
└───────────────────┬───────────────────────────┘
                    │ SFP+ trunk (VLANs 10, 40, 99)
┌───────────────────┴───────────────────────────┐
│  MikroTik CRS310 — core / distribution        │
└────┬──────────────┬───────────────┬───────────┘
     │              │               │
┌────┴────┐   ┌─────┴─────┐    ┌────┴────┐
│  pve1   │   │   pve2    │    │  pve3   │  Proxmox VE cluster
│  CP+WK  │   │   CP+WK   │    │  CP+WK  │  3x i5-8500T / 32GB
└────┬────┘   └─────┬─────┘    └────┬────┘  Mellanox 10GbE SFP+
     │              │               │
┌────┴──────────────┴───────────────┴────┐
│  MikroTik CRS305 — access              │
│  VLAN 20: Longhorn storage replication │
│  (isolated east-west, not routed)      │
└────────────────────────────────────────┘

K3s v1.34 — embedded etcd HA
├── 3x control plane  (4 vCPU / 10GB RAM)
└── 3x worker         (2 vCPU / 12GB RAM)
    VIP: kube-vip (floating)
```

## Stack

| Layer | Tool | Status |
|-------|------|--------|
| Hypervisor | Proxmox VE | Running |
| K8s distribution | K3s (embedded etcd HA) | Running |
| Load balancer | kube-vip + MetalLB | Running |
| Storage | Longhorn (replicated block storage) | Running |
| Ingress | ingress-nginx | Running |
| TLS | cert-manager | Running |
| Monitoring | kube-prometheus-stack (Prometheus, Grafana, Alertmanager) | Running |
| Chart management | Helmfile | Running |
| Secrets | SOPS + age | Planned |
| GitOps | Argo CD | Planned |
| Policy enforcement | Kyverno | Planned |
| Log aggregation | Loki | Planned |
| Node config | Ansible | Planned |
| VM provisioning | Terraform (bpg/proxmox) | Planned |
| Firewall / VPN | OPNsense + WireGuard | Running |
| Networking | MikroTik (VLAN trunk, 10GbE SFP+) | Running |

## Repo Layout

```
.
├── ansible/              # Node configuration (planned)
├── docs/                 # Runbooks, architecture decisions
├── hack/                 # Utilities and one-off scripts
├── kubernetes/
│   ├── apps/             # Application workloads
│   ├── bootstrap/        # Argo CD application manifests
│   ├── core/             # Cluster infrastructure (ingress, storage, policies)
│   ├── monitoring/       # Observability stack
│   └── security/         # Policy enforcement, registry scanning
├── terraform/            # VM provisioning (planned)
└── helmfile.yaml         # Declarative Helm release management
```

Resources like ingresses, PDBs, ServiceMonitors, and NetworkPolicies are co-located with their workload; not centralized.

## Principles

- **GitOps-first:** The repo is the source of truth. Nodes are runtime targets, not places to edit files.
- **Rebuild from scratch:** Every layer is designed to be reproducible from code. No snowflake state.
- **Idempotent and modular:** Each component is independently deployable, testable, and replaceable.
