# Terraform — Proxmox VM Provisioning

Manages the lifecycle of all Proxmox VMs using the [bpg/proxmox](https://registry.terraform.io/providers/bpg/proxmox/latest) provider.

## What belongs here

- `main.tf` — provider config, Proxmox API connection
- `variables.tf` — VM specs (vCPU, RAM, disk), network config, node placement
- `vms.tf` (or per-node files) — VM resource definitions for all 6 K3s nodes
- `outputs.tf` — IP addresses, VM IDs for downstream use by Ansible
- `terraform.tfvars` — variable values (excluded from git if sensitive)
- `versions.tf` — required provider and Terraform version constraints

## Design notes

- Cloud-init is disabled on all VMs — Terraform handles only VM lifecycle (create, resize, destroy), not OS-level config
- OS configuration (packages, users, swap, kernel params) is handled by Ansible after Terraform provisions the VM
- State should be stored locally (no remote backend needed for a homelab), but the state file must be gitignored
- VM placement must respect the topology: one CP + one worker per Proxmox host (pve1, pve2, pve3)

## Files to gitignore

```
*.tfstate
*.tfstate.backup
.terraform/
.terraform.lock.hcl
terraform.tfvars  # if it contains API tokens
```
