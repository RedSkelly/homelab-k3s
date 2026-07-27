# CLAUDE.md: homelab-k3s

This file is the project-level context for Claude Code. It describes the infrastructure, architecture decisions, operational constraints, and development principles for this homelab Kubernetes platform.

## What This Project Is

A production-patterned K3s homelab. The deliverable is the deployment pipeline and the operational patterns, not the workloads.

## Cluster Topology

### Hardware
- 4x Lenovo M920Q nodes total:
  - 3x running Proxmox VE (cluster: `homelab-pve`); each has Intel i5-8500T (6 cores / 6 threads, no HT, which is the physical CPU budget per host), Mellanox dual 10GbE SFP+ NIC, 32GB RAM, 256GB NVMe SSD, 1TB SATA SSD
  - 1x running OPNsense bare metal as upstream firewall/router; same hardware spec
- VMs provisioned on Proxmox; cloud-init is disabled on all VMs
  - pve1: 1 control plane, 1 worker
  - pve2: 1 control plane, 1 worker
  - pve3: 1 control plane, 1 worker
  - pve3 additionally hosts the Tailscale subnet router LXC (CTID 200, 1 vCPU / 512 MB, near-idle); see Networking

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
  - VLAN 10: PROXMOX (cluster infrastructure)
  - VLAN 20: provisioned for storage replication (CRS305-only, east-west, not routed), but Longhorn does not use it (`storage-network` unset, so replication rides VLAN 10). Unused; see Known Open Items and `docs/benchmarks/storage-replication/`.
  - VLAN 40: CLIENT_LAN (user devices, wireless AP)
  - VLAN 99: MGMT (out-of-band management, JetKVM)
- **MTU:** 9000 (jumbo) on the VLAN 10/20 node interfaces (`enp6s18`, `enp6s19`); `flannel.1` at 8950. Set only at the Proxmox host + CRS305 switch layers, so guests inherit it with no backstop: a hypervisor/NIC reset or VM rebuild drops them to 1500, degrading throughput with no error. Ownership belongs in Terraform (VM lifecycle). Benchmark detail and the `set-storage-mtu.sh` caveat live in `docs/benchmarks/storage-replication/`.
- **WireGuard VPN:** Road warrior config for remote management from PC and Mac workstations
- **Tailscale subnet router:** Debian LXC on pve3 (CTID 200), single-homed on VLAN 10, advertises `10.0.10.0/24` into the tailnet for CGNAT remote access, since inbound WireGuard cannot traverse the carrier-grade-NAT WAN. Tagged/non-expiring node; ACL restricts the route to the operator's identity and is the sole compensating control, as the cluster has zero NetworkPolicies. Deliberately isolated: not on any K3s node or OPNsense. Management plane (VLAN 99) is intentionally not remotely reachable. See `docs/tailscale-subnet-router.md`.
- **DNS:** OPNsense Unbound, serving CLIENT_LAN, MGMT, PROXMOX, and VPN interfaces
- **Segmentation:** CLIENT_LAN is blocked from all infrastructure VLANs by design

### K3s Platform Stack (current)
Version = the running app version; Helm chart version noted in the Install Method column.

| Component             | Version | Install Method      | Notes                                    |
|-----------------------|---------|---------------------|------------------------------------------|
| kube-vip              | v0.8.2  | static pod          | Floating VIP for API server HA           |
| MetalLB               | v0.14.5 | kubectl manifest    | LoadBalancer IP allocation               |
| Longhorn              | v1.6.2  | kubectl manifest    | Sole default StorageClass                |
| cert-manager          | v1.19.2 | Argo CD                | First Helmfile→Argo CD migration (2026-04-29) |
| ingress-nginx         | v1.14.1 | Argo CD (chart 4.14.1) | Multi-source $values; values file in repo |
| kube-prometheus-stack | v0.88.0 | Argo CD (chart 81.0.0) | App ver = prometheus-operator; multi-source values + SOPS overlay; cert-manager-issued admission-webhook cert |
| Argo CD               | v3.3.8  | Helm (chart 9.5.9)     | Non-HA; SOPS+age on repo-server; bootstrap only |

## Repo Structure

```
kubernetes/    # All cluster manifests: apps/, bootstrap/argocd/, core/, monitoring/, security/
ansible/       # Node config: swap, kernel, k3s, sudoers, ssh (planned)
terraform/     # Proxmox VM lifecycle, bpg/proxmox (planned)
docs/          # Runbooks, architecture decisions, benchmarks
hack/          # Scripts and utilities
helmfile.yaml  # Bootstrap/break-glass Helm (now only argocd)
```

Workload resources (ingress, PDBs, ServiceMonitors, NetworkPolicies) co-locate with their workload directory, not in central directories. Cluster-scoped resources that span workloads (PriorityClasses) live in `policies/`.

## Management Hosts

- Two workstations (PC + Mac) reach the cluster over two independent, additive overlays: OPNsense WireGuard (works when the client can reach the OPNsense WAN) and the Tailscale subnet router (works from anywhere, including CGNAT LTE). WireGuard is unchanged.
- Both have kubectl, helm, jq, sops, age, Claude Code installed
- SSH keys pushed from both workstations to all 6 nodes
- Kubeconfig on both points to kube-vip VIP, context name: `homelab`
- **macOS sed note:** `sed -i ''` on macOS vs `sed -i` on Linux

**Important:** `/etc/rancher/k3s/k3s.yaml` is the authoritative kubeconfig source. It is always rewritten to `127.0.0.1` on k3s restart/upgrade; requires `sed` fix on every pull. `~/.kube/config` on any node is a manually maintained copy and is NOT authoritative.

## IaC Stack

| Layer              | Tool                          | Purpose                          | Status         |
|--------------------|-------------------------------|----------------------------------|----------------|
| Chart management   | Helmfile                      | Bootstrap/break-glass Helm releases | Complete    |
| Secrets encryption | SOPS + age                    | Encrypt secrets in Git           | Complete       |
| GitOps reconciler  | Argo CD                       | Continuous delivery from Git     | Running        |
| Node configuration | Ansible                       | OS-level config, packages        | Planned        |
| VM provisioning    | Terraform (bpg/proxmox)       | Proxmox VM lifecycle             | Planned        |
| Dependency updates | Renovate                      | Automate PR-based updates        | Planned        |
| Git hygiene        | Pre-commit                    | Linting, validation on commit    | Planned        |

**Current state:** No Terraform or Ansible exists yet. Provisioning was done manually via SSH/shell scripts. Longhorn and MetalLB installed via kubectl manifest. Helmfile now manages only `argocd` (bootstrap/break-glass); cert-manager (2026-04-29), ingress-nginx (2026-07-25), and kps (2026-07-26) are all migrated to Argo CD. cert-manager is single-source with values inlined as `valuesObject` (they are chart defaults); ingress-nginx and kps are multi-source, referencing their in-repo values by path via a `$values` source-ref (a second source tracking the `main` branch). Values files migrated to repo (2026-04-25). Working files deleted from k3s-cp-01.

## Implementation Roadmap

Ordered by dependency chain; each step enables the next:

1. ~~**Helmfile:** Declare cert-manager, ingress-nginx, kps as Helmfile releases. Clean up kps 29 revisions. Migrate kps PVCs from `longhorn-storage-heavy` → `longhorn` SC. MetalLB/Longhorn/kube-vip Helm migration deferred.~~
2. ~~**SOPS + age:** Wire `.sops.yaml`, generate age key, encrypt Slack webhook and any other secrets. Must complete before Argo CD.~~
3. ~~**Argo CD:** Install via Helmfile with SOPS+age integration; migrate all Helmfile releases.~~ Complete. Deployed non-HA (chart 9.5.9, app v3.3.8); cert-manager (2026-04-29), ingress-nginx (2026-07-25), and kps (2026-07-26) migrated. Helmfile now manages only `argocd`. Pattern: create an Application at the exact chart version, `ServerSideApply` sync, remove from helmfile.yaml, delete the Helm release secret. ingress-nginx and kps reference in-repo values by path (multi-source `$values`); cert-manager inlined its chart-default values as `valuesObject`. Argo CD is the reconciler for all steps below.
4. **Kyverno:** First workload deployed via Argo CD. Policies for resource limits + default NetworkPolicies.
5. **Loki:** Centralized logging, deployed via Argo CD.
6. **Ansible:** Codify node config (swap, kernel, k3s config, sudoers, SSH keys) as idempotent playbooks. Parallel track.
7. **Terraform:** Proxmox VM lifecycle. After Ansible.

Deferred: CI pipeline, Harbor+Trivy, Vault+External Secrets, Hugo portfolio site.

## Known Open Items

- Longhorn backup target unconfigured.
- VLAN 20 carries no Longhorn traffic (`storage-network` unset); a dedicated 10GbE segment sits idle while storage contends with cluster/API/pod traffic on VLAN 10. Decide: point Longhorn at it (needs a Multus NetworkAttachmentDefinition) or retire the segment and stop describing it as storage replication. Expected gain is isolation, not speed: both VLANs benchmark identically (~9.5 Gbps), and the write bottleneck was CPU, not network.
- SATA SSD write ceiling assumed ~500 MB/s but never measured on actual disks; replicas measured disk-bound (iowait ~27%) but headroom unquantified. Measure before acting on any disk-bound conclusion.
- Each pve host now 7 vCPU (CP 4 + worker 3) on 6 physical cores; etcd CP shares an oversubscribed host with a storage worker (steal ~0.3-0.5%). Structural, not urgent. pve3 also runs the 1-vCPU Tailscale LXC (idle, negligible steal).
- Worker memory ballooning disabled 2026-07-27 (`qm set 103|104|105 --balloon 0`); the workers had `balloon: 10240` against `memory: 12288`, so the virtio balloon could reclaim 2 GB from a node running Longhorn engines. CP nodes were already `balloon: 0`. Applied live on the Proxmox hosts, so it lives only in `/etc/pve/qemu-server/*.conf`: `balloon = 0` belongs in the Terraform worker resource or a VM rebuild reintroduces it. Same ownership gap as the jumbo-MTU item.
- Kubelet node capacity on the workers under-reports real memory, because the balloon had inflated before each kubelet registered and cAdvisor caches machine info at start. Measured 2026-07-27 against a guest `MemTotal` of 12228672 kB: k3s-wk-01 -202 MiB, k3s-wk-02 -1.6 GiB, k3s-wk-03 -362 MiB. The drift is conservative (the scheduler sees less memory than exists), so this is unschedulable capacity, not an OOM risk. It will not self-correct; recovering it needs a kubelet restart per worker via the standard drain sequence. Low urgency, fold into the next planned worker maintenance.
- Zero NetworkPolicies.
- Missing resource requests/limits on pods.
- Set a longer duration (e.g. 8760h / 1 year) on the cert-manager CA cert to cut renewal churn (leaf certs are 90-day, auto-renewing ~30 days before expiry).
- Longhorn/MetalLB/kube-vip not managed by Helm yet (future Helmfile migration).
- Install helmfile-secrets to Windows as well, modify its plugin file to disable(?) deployment and work as CLI instead, like was done on Mac.
- The ingress-nginx Argo CD Application is multi-source: it references the in-repo values file by path via a `$values` source-ref, which relies on Argo CD anonymously cloning the public GitHub repo (no repository secret is configured). If the repo is made private, this ref breaks: register the repo in Argo CD (a read-only deploy key/token repository secret) before flipping visibility. cert-manager is unaffected (its values are inlined as `valuesObject`). kps (migrated 2026-07-26) uses the same multi-source pattern and inherits this dependency; its SOPS overlay is consumed via helm-secrets wrapper mode, a plain `$values/…/secrets.values.yaml` path, not the `secrets://` scheme, which is incompatible with the `$values` ref (Argo will not expand `$values` behind a scheme prefix).
- kps has two settings that must not be reverted without reading the reason first:
  - `prometheusOperator.admissionWebhooks.certManager.enabled: true` (set 2026-07-26). The chart's default kube-webhook-certgen Jobs are Helm `pre-install`/`pre-upgrade` hooks that wedge Argo CD syncs: the Job finishes in ~2s and is hook-deleted before Argo records success, parking the sync on "waiting for completion of hook" indefinitely. It survives a controller restart (the stuck state persists in `.status.operationState`); recovery requires forcing the op to `Terminating` via a status patch. With cert-manager issuing the webhook cert there are no hooks, so normal full syncs work. Switching it on is a two-phase transition: the operator pod CrashLoops on a missing cert until the self-signed→root→admission cert chain issues, so do a full sync rather than a selective one.
  - `grafana.adminPassword` pinned in the SOPS overlay (`secrets.values.yaml`). Without it the chart generates a fresh random password on every `helm template`, so the repo-server render is non-deterministic: the grafana Secret + Deployment (`checksum/secret`) sit permanently OutOfSync and every sync re-randomizes the admin password.
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

### Writing Style

Applies to every file in this repo: docs, READMEs, code comments, manifest headers, and commit messages.

- **No em dashes.** Use a colon, comma, semicolon, parentheses, or a sentence break, whichever the grammar calls for. Use a hyphen for numeric ranges.
- **No exaggeration.** Drop intensifiers and editorial verdicts ("critical", "the check that matters most", "textbook", "dead weight"). State the fact and its consequence and let the reader judge.
- **Objective and measured.** Prefer a measured number to an adjective. If a figure is assumed rather than measured, say which.
- **No superfluous statements.** Do not restate a conclusion in more than one place, do not justify a convention already stated elsewhere, and do not reproduce `--help` output.
- **Comments explain why, not what.** Omit rationale the reader can get from the code, the chart docs, or a linked file. A comment longer than the config it heads belongs in `docs/`.
- Reserve bold and capitals for a warning that prevents data loss or an outage.

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
- **Never SSH into a node to edit files in place.** Config flows from the workstation via kubectl/Helm/Argo CD; nodes are runtime targets only.
- **Never commit unencrypted secrets.** Everything sensitive is SOPS+age-encrypted before it touches Git.
- **Never `git add`, stage, commit, or push unless explicitly asked.** The operator owns the staging/commit workflow; suggest terse commit messages instead.
- **Never reboot more than one control-plane node at a time**, and never drain/reboot a worker without first checking Longhorn replica health.
- **Don't put raw `kubectl -o yaml` or state dumps in the repo.** Hand-authored, intent-based config only.
- **Don't assume cloud-scale headroom.** Respect the ~21 vCPU / ~66 GB budget.
