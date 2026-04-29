# CLAUDE.md — homelab-k3s

This file is the project-level context for Claude Code. It describes the infrastructure, architecture decisions, operational constraints, and development principles for this homelab Kubernetes platform.

## What This Project Is

A production-patterned K3s homelab designed as a living portfolio. The value is in the deployment pipeline and operational patterns, not the workloads themselves. Every layer should be explainable as a coherent platform engineering narrative.

## Cluster Topology

### Hardware
- 4x Lenovo M920Q nodes total:
  - 3x running Proxmox VE (cluster: `homelab-pve`); each has Intel i5-8500T, Mellanox dual 10GbE SFP+ NIC, 32GB RAM, 256GB NVMe SSD, 1TB SATA SSD
  - 1x running OPNsense bare metal as upstream firewall/router; same hardware spec
- VMs provisioned on Proxmox; cloud-init is disabled on all VMs
  - pve1: 1 control plane, 1 worker
  - pve2: 1 control plane, 1 worker
  - pve3: 1 control plane, 1 worker

### K3s Cluster
- **Version:** k3s v1.34.3+k3s1, embedded etcd HA
- **OS:** Ubuntu 24.04, kernel 6.8.0-110-generic
- **Control plane (3 nodes):**
  - k3s-cp-01 / 02 / 03 on VLAN 10 (4 vCPU / 10GB RAM / 64GB disk, from NVMe SSD)
- **Workers (3 nodes):**
  - k3s-wk-01 / 02 / 03 on VLAN 10 (2 vCPU / 12GB RAM / 64GB disk, from NVMe SSD)
- **kube-vip:** Floating VIP on VLAN 10, one pod per CP node
- **SSH user:** `k3s` (passwordless sudo on all nodes)
- **Swap:** Disabled on all 6 nodes (etcd latency on CP; consistency on workers)

### Networking
- **Firewall:** OPNsense on dedicated M920Q (bare metal, upstream of Proxmox)
- **Switches:** MikroTik CRS310 (core/distribution), CRS305 (access)
- **VLANs:**
  - VLAN 10 — PROXMOX (cluster infrastructure)
  - VLAN 20 — Storage replication (CRS305-only, east-west traffic, not routed through OPNsense)
  - VLAN 40 — CLIENT_LAN (user devices, wireless AP)
  - VLAN 99 — MGMT (out-of-band management, JetKVM)
- **WireGuard VPN:** Road warrior config for remote management from PC and Mac workstations
- **DNS:** OPNsense Unbound, serving CLIENT_LAN, MGMT, PROXMOX, and VPN interfaces
- **Segmentation:** CLIENT_LAN is blocked from all infrastructure VLANs by design

### K3s Platform Stack (current)
| Component             | Version  | Install Method   | Notes                                    |
|-----------------------|----------|------------------|------------------------------------------|
| kube-vip              | v0.8.2   | static pod       | Floating VIP for API server HA           |
| MetalLB               | v0.14.5  | kubectl manifest | LoadBalancer IP allocation               |
| Longhorn              | v1.6.2   | kubectl manifest | **Sole default StorageClass**            |
| cert-manager          | v1.19.2  | Argo CD          | First Helmfile-to-ArgoCD migration       |
| ingress-nginx         | v4.14.1  | Helm (3 rev)     | Values file in repo                      |
| kube-prometheus-stack | v81.0.0  | Helm (29 rev)    | Values file in repo; ~~needs revision cleanup~~ |
| Argo CD               | v3.3.8   | Helm (1 rev)     | Non-HA; SOPS+age on repo-server          |

## Repo Structure

```
.
├── CLAUDE.md                          # This file — project context for Claude Code
├── README.md
├── helmfile.yaml                      # Declarative Helm releases
├── ansible/
│   ├── inventory/                     # Planned: host vars, group vars
│   ├── playbooks/                     # Planned: node config playbooks
│   └── roles/                         # Planned: swap, kernel, k3s, sudoers, ssh
├── docs/                              # Runbooks, architecture decisions
├── hack/                              # One-off scripts, utilities
├── kubernetes/
│   ├── apps/
│   │   └── hugo-portfolio/            # Planned: capstone workload
│   ├── bootstrap/
│   │   └── argocd/
│   │       ├── applications/
│   │       │   └── cert-manager.yaml  # First Argo CD Application (migrated from Helmfile)
│   │       └── values.yaml            # Non-HA, insecure mode, helm-secrets/SOPS/age on repo-server
│   ├── ci/                            # Planned: CI pipeline config
│   ├── core/
│   │   ├── cert-manager/
│   │   │   └── values.yaml            # Argo CD-managed; referenced by Application valuesObject
│   │   ├── external-secrets/          # Planned: Vault+ESO (deferred)
│   │   ├── ingress-nginx/
│   │   │   └── values.yaml            # 2 replicas, worker nodeSelector, topology spread
│   │   ├── kube-vip/                  # Planned: Helm migration from static pod
│   │   ├── longhorn/
│   │   │   ├── ingress.yaml           # longhorn.homelab.local, TLS via cert-manager
│   │   │   ├── pdb.yaml               # PDBs: longhorn-manager, ui, driver-deployer
│   │   │   ├── recurringjob-hourly.yaml  # Hourly snapshots, retain 24
│   │   │   ├── servicemonitor.yaml    # Prometheus scraping via kps release label
│   │   │   └── storageclass-test.yaml # 1-replica SC for dev/test
│   │   ├── metallb/                   # Planned: Helm migration from kubectl manifest
│   │   └── policies/
│   │       ├── pdb-kube-system.yaml   # CoreDNS (minAvail 1), kube-vip (minAvail 2)
│   │       └── priorityclasses.yaml   # infra-critical, infra, apps (default), batch-low
│   ├── monitoring/
│   │   ├── kube-prometheus-stack/
│   │   │   ├── values.yaml            # Grafana/Prometheus/Alertmanager with ingresses,
│   │   │   │                          # Longhorn alert rules.
│   │   │   │                          # storageClassName: longhorn (prepped for PVC migration)
│   │   │   └── secrets.values.yaml    # SOPS-encrypted Helmfile values overlay
│   │   │                              # Slack webhook provided via SOPS-encrypted secrets overlay
│   │   └── loki/                      # Planned: centralized logging
│   └── security/
│       ├── harbor/                    # Planned: container registry (deferred)
│       └── kyverno/                   # Planned: policy enforcement
└── terraform/
    └── proxmox/                       # Planned: bpg/proxmox provider for VM lifecycle
```

Workload resources (ingress, PDBs, ServiceMonitors, NetworkPolicies) co-locate with their workload directory, not in central directories. Cluster-scoped resources that span workloads (PriorityClasses) live in `policies/`.

## Management Hosts

- Two workstations (PC + Mac) connect over WireGuard VPN
- Both have kubectl, helm, jq, sops, age, Claude Code installed
- SSH keys pushed from both workstations to all 6 nodes
- Kubeconfig on both points to kube-vip VIP, context name: `homelab`
- **macOS sed note:** `sed -i ''` on macOS vs `sed -i` on Linux

**Important:** `/etc/rancher/k3s/k3s.yaml` is the authoritative kubeconfig source. It is always rewritten to `127.0.0.1` on k3s restart/upgrade; requires `sed` fix on every pull. `~/.kube/config` on any node is a manually maintained copy and is NOT authoritative.

## IaC Stack

| Layer              | Tool                          | Purpose                          | Status         |
|--------------------|-------------------------------|----------------------------------|----------------|
| Chart management   | Helmfile                      | Declarative Helm releases        | Complete       |
| Secrets encryption | SOPS + age                    | Encrypt secrets in Git           | Complete       |
| GitOps reconciler  | Argo CD                       | Continuous delivery from Git     | Running        |
| Node configuration | Ansible                       | OS-level config, packages        | Planned        |
| VM provisioning    | Terraform (bpg/proxmox)       | Proxmox VM lifecycle             | Planned        |
| Dependancy updates | Renovate                      | Automate PR-based updates        | Planned        |
| Git hygiene        | Pre-commit                    | Linting, validation on commit    | Planned        |

**Current state:** No Terraform, Ansible, ~~or Helmfile~~ exists yet. Provisioning was done manually via SSH/shell scripts. Longhorn and MetalLB installed via kubectl manifest. Helmfile manages ingress-nginx, kps, and argocd. cert-manager migrated to Argo CD management (2026-04-29). Values files migrated to repo (2026-04-25). Working files deleted from k3s-cp-01.

## Implementation Roadmap

Ordered by dependency chain — each step enables the next:

1. ~~**Helmfile:** Declare cert-manager, ingress-nginx, kps as Helmfile releases. Clean up kps 29 revisions. Migrate kps PVCs from `longhorn-storage-heavy` → `longhorn` SC. MetalLB/Longhorn/kube-vip Helm migration deferred.~~
2. ~~**SOPS + age:** Wire `.sops.yaml`, generate age key, encrypt Slack webhook and any other secrets. Must complete before Argo CD.~~
3. **Argo CD:** ~~Install Argo CD via Helmfile with SOPS+age integration.~~ Deployed (non-HA, Helm chart 9.5.9, app v3.3.8). ~~First migration: cert-manager moved from Helmfile to Argo CD (2026-04-29).~~ Next: migrate remaining Helmfile releases (ingress-nginx, kps), expand to full stack. Migration pattern: create Application with exact chart+values, sync with ServerSideApply, remove from helmfile.yaml, delete Helm release secret.
4. **Kyverno:** First workload deployed via Argo CD. Policies for resource limits + default NetworkPolicies.
5. **Loki:** Centralized logging, deployed via Argo CD.
6. **Ansible:** Codify node config (swap, kernel, k3s config, sudoers, SSH keys) as idempotent playbooks. Parallel track.
7. **Terraform:** Proxmox VM lifecycle. After Ansible. Portfolio value, not operational urgency.

Deferred: CI pipeline, Harbor+Trivy, Vault+External Secrets, Hugo portfolio site.

## Known Open Items

- **CLOSED** ~~kps PVCs on `longhorn-storage-heavy` SC; need migration to `longhorn`, then delete `longhorn-storage-heavy`.~~
- Longhorn backup target unconfigured.
- Zero NetworkPolicies.
- Missing resource requests/limits on pods.
- **CLOSED** ~~cert-manager certs expire June 2026~~ Auto-renewal is 2026-05-19. 90-day duration and renewal at 2/3 of the lifetime (i.e., 30 days before expiry).
  - TODO: Set a longer duration (e.g., 8760h / 1 year) on the CA cert to reduce churn and risk.
- **CLOSED** ~~kube-prometheus-stack has 29 Helm revisions (cleanup needed).~~
- Longhorn/MetalLB/kube-vip not managed by Helm yet (future Helmfile migration).
- Install helmfile-secrets to Windows as well, modify its plugin file to disable(?) deployment and work as CLI instead, like was done on Mac.

## Development Principles

### Automation First
- **Idempotency:** Every operation (Terraform apply, Ansible playbook, Helmfile sync) must be safe to run repeatedly with identical results. No snowflake state.
- **Modularity:** Each component should be independently deployable, testable, and replaceable. Avoid monolithic configs that couple unrelated concerns.
- **Nodes are runtime targets only:** All configuration editing happens on the workstation and flows to the cluster via kubectl/Helm/Argo CD; never SSH into a node and edit files in place.

### Repo Philosophy
- GitOps-first, intent-based (not state-dump).
- Clean hand-authored values files only, no raw `kubectl get -o yaml` extracts.
- The repo tells a rebuild-from-scratch story.
- Workload resources (ingress, PDBs, ServiceMonitors, NetworkPolicies) co-locate with their workload, not in central directories.

### Operational Discipline
- **Longhorn drain sequencing:** Always check Longhorn replica health before draining any node. Uncordon must happen *before* Longhorn will rebuild replicas.
- **Control plane reboot:** Never reboot more than one CP node at a time. Verify etcd shows 3 healthy members (`etcdctl endpoint status --cluster -w table`) before proceeding to next. Longhorn volume health is a hard gate.
- **Worker vs CP drain:** Workers require full drain. CP nodes require cordon + one-at-a-time sequencing. Drain on CP is conditional on whether workloads are scheduled there.
- **CP maintenance sequence:** cordon → verify etcd → reboot → uncordon when Ready → verify etcd restored → node.
- **Worker maintenance sequence:** cordon →drain → reboot → uncordon → verify Longhorn healthy → next node.

### What Claude Code Should Do
- Flag non-optimal setup decisions proactively and suggest improvements.
- Prefer automation over manual steps; if something can be codified, codify it.
- When writing manifests/values files, include comments explaining *why* a value is set, not just what it is.
- Keep resource footprint in mind; this is a homelab, not a cloud account with infinite headroom (total cluster: ~18 vCPU, ~66GB RAM across 6 nodes).
- Validate changes against the cluster topology before suggesting them (e.g., don't assume unlimited replicas).
- When in doubt, check the actual cluster state with kubectl rather than assuming.
- HELM_MAX_HISTORY=5 is set; keep revision count low.
