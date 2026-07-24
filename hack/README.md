# Hack — Utility Scripts

Operational scripts and helpers that don't fit neatly into Terraform, Ansible, or Kubernetes manifests. The scripts live in `hack/scripts/`.

## What's here

| Script                       | Purpose                                                                  |
|------------------------------|--------------------------------------------------------------------------|
| `preflight-check.sh`         | Go/no-go gate before any drain, reboot, or shutdown (exit 0 = safe)       |
| `k3s-diag.sh`                | Cluster-wide read-only diagnostic; exits 1 if it finds problems          |
| `linux-diag.sh`              | OS-level per-node diagnostic; surfaces drift between identical nodes      |
| `proxmox-diag.sh`            | Read-only diagnostic for the Proxmox hosts underneath the VMs            |
| `check-kernel-drift.sh`      | Kernel + unattended-upgrades state across all nodes                      |
| `set-journald-persistent.sh` | Make the systemd journal survive reboot on every node                   |
| `set-storage-mtu.sh`         | Set MTU 9000 on the workers' VLAN 20 interface (does not affect Longhorn) |

## Planned

- `kubeconfig-fix.sh` — rewrite the kube-vip VIP in kubeconfig after a K3s restart resets it to `127.0.0.1` (see CLAUDE.md). Not yet written; the fix is currently a manual `sed`.

## Design notes

- Scripts here are operational helpers, not deployment tools
- As the IaC stack matures, many of these should migrate into Ansible playbooks or CI pipelines (e.g. orchestrated rolling reboots belong in an Ansible `reboot.yml`, not a script here)
- All scripts should be idempotent and safe to run repeatedly
- Include usage comments and validation (check prereqs before executing)
