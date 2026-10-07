# ADR 0003: Toolchain and layer ownership

## Status

Proposed, 2026-10-07. Sets which tool owns each layer of the homelab, from network devices to workloads, and the order in which the remaining gaps close. Backup and restore are in ADR 0004. Implementation steps are out of scope; each layer gets its own change, and its own ADR where a choice needs recording.

## Rules

The principles in the repo `README.md` apply. Six rules follow from them:

1. The API a tool talks to sets its boundary. Terraform owns objects behind a provider API (Proxmox, Tailscale, Cloudflare), Ansible owns state inside a host's OS, and Argo CD owns objects in the Kubernetes API.
2. One owner per resource. Two tools reconciling the same object overwrite each other, as kube-vip shows (`kubectl` apply, then a k3s AddOn; ADR 0002).
3. Bootstrap order has no cycles. A component that Argo CD needs in order to run (DNS, the CNI, the API server) belongs to a layer below Argo CD.
4. Changes reach the homelab only by pull or from an operator workstation. CI validates and holds no Proxmox, SSH, or cluster credentials.
5. A component moves to its final owner at its running version and settings, with no interim owner. Upgrades are separate changes.
6. A layer counts as reproducible only after its rebuild has been run (see Verification).

## Current state

Verified 2026-10-07 from the repo and with kubectl.

- Reconciled from Git: cert-manager, ingress-nginx, and kube-prometheus-stack as Argo CD Applications (manual sync, `default` AppProject), and Argo CD itself through Helmfile. The three Applications were created with `kubectl apply`; there is no root Application.
- In Git, applied by hand: the Longhorn recurring job and the Longhorn and kube-system PDBs (field manager `kubectl-client-side-apply`).
- Not in code: the MetalLB and Longhorn installs; kube-vip (ADR 0002); k3s server and agent configuration; the CoreDNS replica count; the worker label `node-role.kubernetes.io/worker`, set with `kubectl label` on 2026-01-21 and selected on by the Argo CD and ingress-nginx values; settings that exist only on the Proxmox hosts (`balloon: 0`, MTU 9000, bridges); OPNsense and MikroTik configuration; the Tailscale ACL. The Tailscale LXC exists as a shell runbook.
- `ansible/` and `terraform/` contain READMEs only. No CI, pre-commit, or Renovate configuration exists.

## Decision

| Layer | Owner | Scope |
|---|---|---|
| Network devices | Backups (ADR 0004), not code | OPNsense, CRS310, CRS305 |
| Proxmox hosts | Ansible | Bridges, VLANs, MTU 9000, repositories, NTP, journald, NUT (planned) |
| Guests | Terraform (bpg/proxmox) | VMs and the Tailscale LXC: CPU, memory, `balloon: 0`, disks, NICs, VLAN tags, MTU, first-boot identity |
| Guest OS and k3s | Ansible | Packages, sysctl, swap, SSH, Longhorn prerequisites, k3s install, config, and upgrades, CoreDNS replicas, workstation kubeconfig, Tailscale LXC internals (IP forwarding, tagged-key join) |
| Cluster bootstrap | Ansible playbook calling Helmfile | `argocd/sops-age` Secret, Argo CD install, root Application |
| In-cluster platform and workloads | Argo CD | Everything else, including Argo CD itself |
| External services | Terraform | Tailscale ACL; Cloudflare Tunnel for the Hugo site |
| Backups | Built-in mechanisms (ADR 0004) | Data that Git cannot hold |
| Secrets, all layers | SOPS + age | |
| Version updates, all layers | Renovate (hosted GitHub app) | Pull requests only |
| Validation | GitHub Actions and pre-commit | Static checks |

Only Argo CD reconciles continuously. Terraform and Ansible are push-based and find drift only when run, so the layers below Kubernetes are reproducible from code but not reconciled from Git. A scheduled read-only check (`terraform plan -detailed-exitcode`, `ansible-playbook --check`) reports drift such as the balloon and MTU items. It runs inside the network, because CI holds no homelab credentials (rule 4).

### Cross-layer settings

Jumbo MTU has three owners: the VM NIC (Terraform), the Proxmox bridge (Ansible), and the CRS305 (manual, documented). A mismatch at any of them lowers throughput without an error.

### Network devices

OPNsense routes, filters, resolves DNS, and terminates VPNs for every other layer, and the switches carry every VLAN. A tool that pushes configuration to them can remove the path used to repair them. Their configuration is backed up (ADR 0004), `docs/` holds the intent (VLAN plan, purpose of each firewall rule) and the restore procedure, and declarative management waits until each device has confirmed out-of-band access.

### Proxmox hosts

Installation and cluster membership stay documented one-time steps; the Proxmox automated installer with an answer file in Git is an option for the install. Ansible owns host configuration afterwards, including NUT once it is deployed. The unclean shutdown on May 20 recorded in `docs/tailscale-subnet-router.md` came from pve2's surge-only UPS outlet; without NUT, a power loss stops etcd and Longhorn with no shutdown sequence.

### Guests (Terraform)

- Terraform downloads the Ubuntu 24.04 cloud image itself, so no template-build tool is needed.
- A no-touch rebuild needs hostname, static IP, user `k3s`, and SSH keys at first boot. cloud-init, through the provider's `initialization` block, supplies only that; Ansible does the rest.
- State goes to a remote backend with locking, outside anything Terraform manages, including the bucket that holds it. Two workstations run Terraform, and local state is one unshared copy. State holds provider secrets in plain text, so the backend is private and encrypted.
- `.terraform.lock.hcl` is committed so provider versions are reproducible.
- The Proxmox API token is read from a SOPS file (carlpett/sops provider).
- Existing guests are imported, and the configuration is adjusted until `terraform plan` reports no changes.
- **Every k3s VM carries `lifecycle { prevent_destroy = true }`.** A setting mismatch shared by the three servers makes Terraform plan to replace all three, and it applies replacements in parallel, deleting every etcd member's disk. The same holds for the workers and every Longhorn replica. Replacing a node VM is a deliberate, one-at-a-time operation.

### Guest OS and k3s (Ansible)

- All k3s settings live in `/etc/rancher/k3s/config.yaml`; the unit carries none. The join token comes from SOPS through `token-file`.
- Nodes join through a live server address, never the VIP (ADR 0002). The only kube-vip setting in the k3s role is `tls-san`.
- The k3s version is pinned in inventory. Upgrades and reboots run as rolling playbooks (`serial: 1`) with the gates from the CLAUDE.md maintenance sequences, reusing the checks in `hack/scripts/preflight-check.sh`.
- CoreDNS stays the k3s-packaged addon, because Argo CD needs DNS to reach GitHub (rule 3). Ansible sets its replica count after install.
- The worker label is dropped rather than codified: the control-plane `NoSchedule` taint already keeps untolerating pods off servers, so the `nodeSelector` in the Argo CD and ingress-nginx values adds a manual dependency and no placement constraint.
- Ansible reads secrets through `community.sops` and writes the workstation kubeconfig with the server set to the VIP.

### Cluster bootstrap

One playbook, run from a workstation, creates the `argocd/sops-age` Secret from the operator's age key, runs Helmfile to install Argo CD, and applies the root Application. The age key is the one input Git cannot hold; ADR 0004 covers its recovery. Helmfile keeps Argo CD as its only release, for this step and as the break-glass path.

### In-cluster (Argo CD)

- A root Application over `kubernetes/bootstrap/argocd/applications/` replaces per-Application `kubectl apply`; adding a component is a commit.
- Argo CD manages itself with the values file Helmfile uses.
- MetalLB and Longhorn move directly to Argo CD Applications from their upstream Helm charts (rule 5). kube-vip follows ADR 0002, the ingress controller ADR 0001.
- Helm hooks that stall Argo CD syncs are disabled or replaced: kube-prometheus-stack issues its admission webhook certificate through cert-manager (CLAUDE.md), and Longhorn's Argo CD install guide sets `preUpgradeChecker.jobEnabled: false` [1].
- Sync policy: automated sync with self-heal once CI checks are required on `main`, so drift is corrected instead of only reported. Argo CD itself and Longhorn stay on manual sync, because their upgrades need an operator gate. Prune is enabled per Application once all its resources are in Git.

### Cross-cutting

- SOPS + age is the only secrets system: Terraform (carlpett/sops), Ansible (`community.sops`), Argo CD and Helmfile (helm-secrets). Vault and External Secrets are not adopted: they add a stateful service that must be running and unsealed before any secret resolves, which lengthens every rebuild. Revisit if a workload needs dynamic secrets.
- Renovate opens pull requests for every pinned version (charts, Terraform providers, the k3s version, images). They pass CI before merge; no automerge.
- CI and pre-commit run static checks only: linting, schema validation of rendered manifests, a SOPS encryption check, and secret scanning.

## Not adopted

| Option | Reason |
|---|---|
| Ansible `proxmox_kvm` instead of Terraform | It creates and updates VMs but has no plan that reports drift in VM settings, which is what the balloon and MTU items are. |
| OpenTofu | Its client-side state encryption would allow state in Git, but its built-in key providers are a passphrase or a KMS, not age. Revisit if the state backend becomes a problem. |
| Talos Linux | An immutable, API-configured OS removes the guest OS layer and matches "nodes are runtime targets" more closely than Ubuntu plus Ansible. Adopting it replaces Ubuntu and k3s through a full cluster rebuild, and Longhorn needs Talos system extensions. |
| Packer | The cloud image plus first-boot cloud-init covers what a template would. |
| system-upgrade-controller, kured | A second owner of the k3s version and reboot timing; the etcd and Longhorn gates would need re-implementing inside them. |
| Cluster API, Crossplane, Rancher | A management layer sized for many clusters; this is one. |
| Flux | Argo CD is in place. |
| Vault + External Secrets | See Cross-cutting. |
| Push-based CD, self-hosted runners with homelab access | Breaks rule 4. |

## Supersedes, on acceptance

- `terraform/proxmox/README.md`: "Cloud-init is disabled" (reason not recorded) and local state.
- `ansible/README.md` and `ansible/roles/README.md`: kube-vip settings in the k3s role.
- `kubernetes/core/external-secrets/README.md`: Vault + External Secrets as the SOPS successor.
- `docs/tailscale-subnet-router.md`: operator-maintained ACL and the shell runbook.
- `.gitignore`: the `.terraform.lock.hcl` exclusion.
- CLAUDE.md roadmap order: Ansible starts ahead of Kyverno, because off-node etcd snapshots and the join-token fix need it.

## Adoption order

Each item is its own change; the sequencing in ADR 0001 and ADR 0002 still applies.

1. Age key recovery and backup targets (ADR 0004).
2. A narrow first Ansible role: the existing server `config.yaml` with the etcd S3 settings, and a one-node-at-a-time k3s restart playbook gated on etcd membership and Longhorn health. Run on the workers, the same playbook recovers their under-reported memory capacity.
3. Validation: CI, pre-commit, required checks on `main`; then Renovate.
4. Argo CD root Application and self-management.
5. The rest of the guest OS and k3s configuration in Ansible, adopting the running nodes (`--check --diff` first).
6. Ingress controller (ADR 0001), kube-vip (ADR 0002), then MetalLB and Longhorn into Argo CD.
7. Kyverno, NetworkPolicies, Loki.
8. Terraform imports the existing guests; Ansible takes over the Proxmox hosts and NUT; rebuild drills.

## Verification

- Idempotent: a second run of every playbook reports `changed=0`; `terraform plan` after apply reports no changes; every Application stays Synced without a manual sync; the scheduled drift check reports none.
- GitOps: platform objects carry no `kubectl-client-side-apply`, `kubectl-patch`, or `kubectl-label` field managers.
- Rebuild: a worker drill (recreate one worker with Terraform and Ansible, rejoin, Longhorn rebuilds its replicas), then a control-plane drill under the one-at-a-time rule. Restore tests are in ADR 0004. A full-cluster rehearsal needs spare capacity the hosts do not have (7 vCPU on each 6-core host).

## Open decisions

1. cloud-init for first-boot identity, unless the unrecorded reason for disabling it still applies.
2. Whether `main` keeps accepting direct pushes once checks are required; automated sync depends on it.
3. Where the scheduled drift check runs inside the network.
4. Terraform state backend location. An S3 service chosen for etcd snapshots (ADR 0004) could also hold it.

## References

1. Longhorn docs, Install with Argo CD (v1.6.2): https://longhorn.io/docs/1.6.2/deploy/install/install-with-argocd/
