# homelab-k3s

Production-patterned Kubernetes platform on bare metal, built GitOps-first to be reproducible from code. The value is in the deployment pipeline and operational patterns, not the workloads.

## Highlights

- **HA control plane** — 3-node embedded-etcd K3s behind a kube-vip floating VIP.
- **GitOps migration** — Helmfile → Argo CD, with SOPS + age encrypting secrets in Git.
- **Replicated storage** — Longhorn default StorageClass with documented drain/reboot runbooks.
- **CGNAT remote access** — Tailscale subnet router (isolated LXC), ACL-scoped; WireGuard kept for on-LAN.
- **Measured, not guessed** — storage-replication and jumbo-frame benchmarks under `docs/benchmarks/`.

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
│  VLAN 20: isolated east-west segment   │
│  (provisioned; Longhorn not using it)  │
└────────────────────────────────────────┘

K3s v1.34 — embedded etcd HA
├── 3x control plane  (4 vCPU / 10GB RAM)
└── 3x worker         (3 vCPU / 12GB RAM)
    VIP: kube-vip (floating)

Remote access: OPNsense WireGuard (on-LAN) + Tailscale subnet-router LXC on pve3 (CGNAT)
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
| Secrets | SOPS + age | Running |
| GitOps | Argo CD | Running |
| Policy enforcement | Kyverno | Planned |
| Log aggregation | Loki | Planned |
| Node config | Ansible | Planned |
| VM provisioning | Terraform (bpg/proxmox) | Planned |
| Firewall / VPN | OPNsense + WireGuard | Running |
| Remote access (CGNAT) | Tailscale subnet router (isolated LXC) | Running |
| Networking | MikroTik (VLAN trunk, 10GbE SFP+) | Running |

## Repo Layout

```
.
├── ansible/              # Node configuration (planned)
├── docs/                 # Runbooks, decisions, benchmarks
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

---

See [`docs/`](docs/) for runbooks, architecture decisions, and benchmark results.
