# CLAUDE.md — homelab-k3s

This file is the project-level context for Claude Code. It describes the infrastructure, architecture decisions, operational constraints, and development principles for this homelab Kubernetes platform.

## What This Project Is

A production-patterned K3s homelab designed as a living portfolio. The value is in the deployment pipeline and operational patterns, not the workloads themselves. Every layer should be explainable as a coherent platform engineering narrative.

## Cluster Topology

### Hardware
- 4x Lenovo M920Q nodes total:
  - 3x running Proxmox VE (cluster: `homelab-pve`); each has Intel i5-8500T (**6 cores / 6 threads, no HT** — the physical CPU budget per host), Mellanox dual 10GbE SFP+ NIC, 32GB RAM, 256GB NVMe SSD, 1TB SATA SSD
  - 1x running OPNsense bare metal as upstream firewall/router; same hardware spec
- VMs provisioned on Proxmox; cloud-init is disabled on all VMs
  - pve1: 1 control plane, 1 worker
  - pve2: 1 control plane, 1 worker
  - pve3: 1 control plane, 1 worker
  - pve3 additionally hosts the Tailscale subnet router LXC (CTID 200, 1 vCPU / 512 MB, near-idle) — see Networking

### K3s Cluster
- **Version:** k3s v1.34.3+k3s1, embedded etcd HA
- **OS:** Ubuntu 24.04, kernel 6.8.0-134-generic
- **Control plane (3 nodes):**
  - k3s-cp-01 / 02 / 03 on VLAN 10 (4 vCPU / 10GB RAM / 64GB disk, from NVMe SSD)
- **Workers (3 nodes):**
  - k3s-wk-01 / 02 / 03 on VLAN 10 (3 vCPU / 12GB RAM / 64GB disk, from NVMe SSD)
  - 3 vCPU chosen empirically: Longhorn's single-threaded per-volume engine starves at 2, clears at 3, and gains little at 4 while adding steal on the co-located etcd CP. Uniform across workers because engine placement follows the attaching pod.
- **kube-vip:** Floating VIP on VLAN 10, one pod per CP node
- **SSH user:** `k3s` (passwordless sudo on all nodes)
- **Swap:** Disabled on all 6 nodes (etcd latency on CP; consistency on workers)

### Networking
- **Firewall:** OPNsense on dedicated M920Q (bare metal, upstream of Proxmox)
- **Switches:** MikroTik CRS310 (core/distribution), CRS305 (access)
- **VLANs:**
  - VLAN 10 — PROXMOX (cluster infrastructure)
  - VLAN 20 — Provisioned for storage replication (CRS305-only, east-west, not routed), but **Longhorn does not use it** (`storage-network` unset — replication rides VLAN 10). Unused; see Known Open Items and `docs/benchmarks/storage-replication/`.
  - VLAN 40 — CLIENT_LAN (user devices, wireless AP)
  - VLAN 99 — MGMT (out-of-band management, JetKVM)
- **MTU:** 9000 (jumbo) on the VLAN 10/20 node interfaces (`enp6s18`, `enp6s19`); `flannel.1` at 8950. Set only at the Proxmox host + CRS305 switch layers — **guests inherit it with no backstop**, so a hypervisor/NIC reset or VM rebuild silently drops them to 1500 (throughput degrades with no error). Ownership belongs in Terraform (VM lifecycle). Benchmark detail and the `set-storage-mtu.sh` caveat live in `docs/benchmarks/storage-replication/`.
- **WireGuard VPN:** Road warrior config for remote management from PC and Mac workstations
- **Tailscale subnet router:** Debian LXC on pve3 (CTID 200), single-homed on VLAN 10, advertises `10.0.10.0/24` into the tailnet for **CGNAT remote access** — inbound WireGuard can't traverse the carrier-grade-NAT WAN. Tagged/non-expiring node; ACL restricts the route to the operator's identity (sole compensating control, cluster has zero NetworkPolicies). Deliberately isolated — not on any K3s node or OPNsense. Management plane (VLAN 99) intentionally **not** remotely reachable. See `docs/tailscale-subnet-router.md`.
- **DNS:** OPNsense Unbound, serving CLIENT_LAN, MGMT, PROXMOX, and VPN interfaces
- **Segmentation:** CLIENT_LAN is blocked from all infrastructure VLANs by design

### K3s Platform Stack (current)
Version = the running app version; Helm chart version noted in the Install Method column.

| Component             | Version | Install Method      | Notes                                    |
|-----------------------|---------|---------------------|------------------------------------------|
| kube-vip              | v0.8.2  | static pod          | Floating VIP for API server HA           |
| MetalLB               | v0.14.5 | kubectl manifest    | LoadBalancer IP allocation               |
| Longhorn              | v1.6.2  | kubectl manifest    | Sole default StorageClass                |
| cert-manager          | v1.19.2 | Argo CD             | First Helmfile→Argo CD migration         |
| ingress-nginx         | v1.14.1 | Helm (chart 4.14.1) | Values file in repo                      |
| kube-prometheus-stack | v0.88.0 | Helm (chart 81.0.0) | App ver = prometheus-operator; values in repo |
| Argo CD               | v3.3.8  | Helm (chart 9.5.9)  | Non-HA; SOPS+age on repo-server          |

## Repo Structure

```
kubernetes/    # All cluster manifests: apps/, bootstrap/argocd/, core/, monitoring/, security/
ansible/       # Node config — swap, kernel, k3s, sudoers, ssh (planned)
terraform/     # Proxmox VM lifecycle, bpg/proxmox (planned)
docs/          # Runbooks, architecture decisions, benchmarks
hack/          # Scripts and utilities
helmfile.yaml  # Declarative Helm releases
```

Workload resources (ingress, PDBs, ServiceMonitors, NetworkPolicies) co-locate with their workload directory, not in central directories. Cluster-scoped resources that span workloads (PriorityClasses) live in `policies/`.

## Management Hosts

- Two workstations (PC + Mac) reach the cluster over **two independent, additive overlays**: OPNsense **WireGuard** (works when the client can reach the OPNsense WAN) and the **Tailscale** subnet router (works from anywhere, including CGNAT LTE). WireGuard is unchanged.
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
| Dependency updates | Renovate                      | Automate PR-based updates        | Planned        |
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

- Longhorn backup target unconfigured.
- VLAN 20 carries no Longhorn traffic (`storage-network` unset); a dedicated 10GbE segment sits idle while storage contends with cluster/API/pod traffic on VLAN 10. Decide: point Longhorn at it (needs a Multus NetworkAttachmentDefinition — non-trivial) or retire the segment and stop describing it as storage replication. Expected gain is **isolation, not speed** — both VLANs benchmark identically (~9.5 Gbps), and the write bottleneck was CPU, not network.
- SATA SSD write ceiling assumed ~500 MB/s but never measured on actual disks; replicas measured disk-bound (iowait ~27%) but headroom unquantified. Measure before acting on any disk-bound conclusion.
- Each pve host now 7 vCPU (CP 4 + worker 3) on 6 physical cores; etcd CP shares an oversubscribed host with a storage worker (steal ~0.3-0.5%). Structural, not urgent. pve3 also runs the 1-vCPU Tailscale LXC (idle, negligible steal).
- Zero NetworkPolicies.
- Missing resource requests/limits on pods.
- Set a longer duration (e.g. 8760h / 1 year) on the cert-manager CA cert to cut renewal churn (leaf certs are 90-day, auto-renewing ~30 days before expiry).
- Longhorn/MetalLB/kube-vip not managed by Helm yet (future Helmfile migration).
- Install helmfile-secrets to Windows as well, modify its plugin file to disable(?) deployment and work as CLI instead, like was done on Mac.
- The ingress-nginx Argo CD Application is multi-source: it references the in-repo values file by path via a `$values` Git ref, which relies on Argo CD **anonymously cloning the public GitHub repo** (no repository secret is configured). If the repo is made private, this ref breaks — register the repo in Argo CD (a read-only deploy key/token repository secret) before flipping visibility. cert-manager is unaffected (its values are inlined as `valuesObject`). kps (migrated 2026-07-26) uses the same multi-source pattern and inherits this dependency; its SOPS overlay is consumed via helm-secrets **wrapper mode** — a plain `$values/…/secrets.values.yaml` path, NOT the `secrets://` scheme, which is incompatible with the `$values` ref (Argo won't expand `$values` behind a scheme prefix).
- **kps has two non-obvious settings that must NOT be naively reverted** (each prevents a problem that is painful to rediscover):
  - `prometheusOperator.admissionWebhooks.certManager.enabled: true` (set 2026-07-26). The chart's default kube-webhook-certgen Jobs are Helm `pre-install`/`pre-upgrade` hooks that reliably **wedge Argo CD syncs**: the Job finishes in ~2s and is hook-deleted before Argo records success, parking the sync on "waiting for completion of hook" indefinitely. It survives a controller restart (the stuck state persists in `.status.operationState`); recovery requires forcing the op to `Terminating` via a status patch. With cert-manager issuing the webhook cert there are no hooks, so **normal full syncs work**. (Switching it on is a two-phase transition: the operator pod CrashLoops on a missing cert until the self-signed→root→admission cert chain issues — do a *full* sync so all issuer resources apply, not a selective one.)
  - `grafana.adminPassword` pinned in the SOPS overlay (`secrets.values.yaml`). Without it the chart generates a fresh random password on every `helm template`, so the repo-server render is non-deterministic — the grafana Secret + Deployment (`checksum/secret`) sit permanently OutOfSync and **every sync re-randomizes the admin password**.
- kps leftover cleanup: after the cert-manager webhook switch, the old kube-webhook-certgen admission RBAC (`kps-kube-prometheus-stack-admission` ServiceAccount/roles/bindings) and its old cert secret may linger unpruned (Argo syncPolicy has no prune). Harmless; remove when convenient.

## Development Principles

### Automation First
- **Idempotency:** Every operation (Terraform apply, Ansible playbook, Helmfile sync) must be safe to run repeatedly with identical results. No snowflake state.
- **Modularity:** Each component should be independently deployable, testable, and replaceable. Avoid monolithic configs that couple unrelated concerns.
- **Nodes are runtime targets only:** All configuration editing happens on the workstation and flows to the cluster via kubectl/Helm/Argo CD; never SSH into a node and edit files in place.

### Repo Philosophy
- GitOps-first, intent-based (not state-dump).
- Clean hand-authored values files only, no raw `kubectl get -o yaml` extracts.
- The repo tells a rebuild-from-scratch story.

### Operational Discipline
- **Longhorn drain sequencing:** Always check Longhorn replica health before draining any node. Uncordon must happen *before* Longhorn will rebuild replicas.
- **Control plane reboot:** Never reboot more than one CP node at a time. Verify etcd shows 3 healthy members (`etcdctl endpoint status --cluster -w table`) before proceeding to next. Longhorn volume health is a hard gate.
- **Worker vs CP drain:** Workers require full drain. CP nodes require cordon + one-at-a-time sequencing. Drain on CP is conditional on whether workloads are scheduled there.
- **CP maintenance sequence:** cordon → verify etcd → reboot → uncordon when Ready → verify etcd restored → node.
- **Worker maintenance sequence:** cordon → drain → reboot → uncordon → verify Longhorn healthy → next node.

### What Claude Code Should Do
- Flag non-optimal setup decisions proactively and suggest improvements.
- Prefer automation over manual steps; if something can be codified, codify it.
- When writing manifests/values files, include comments explaining *why* a value is set, not just what it is.
- Keep resource footprint in mind; this is a homelab, not a cloud account with infinite headroom (total cluster: ~21 vCPU, ~66GB RAM across 6 nodes).
- Validate changes against the cluster topology before suggesting them (e.g., don't assume unlimited replicas).
- When in doubt, check the actual cluster state with kubectl rather than assuming.
- HELM_MAX_HISTORY=5 is set; keep revision count low.

### What Claude Code Should NOT Do
- **Never SSH into a node to edit files in place** — config flows from the workstation via kubectl/Helm/Argo CD; nodes are runtime targets only.
- **Never commit unencrypted secrets** — everything sensitive is SOPS+age-encrypted before it touches Git.
- **Never `git add`, stage, commit, or push unless explicitly asked** — the operator owns the staging/commit workflow; suggest terse commit messages instead.
- **Never reboot more than one control-plane node at a time**, and never drain/reboot a worker without first checking Longhorn replica health.
- **Don't put raw `kubectl -o yaml` or state dumps in the repo** — hand-authored, intent-based config only.
- **Don't assume cloud-scale headroom** — respect the ~21 vCPU / ~66 GB budget.
