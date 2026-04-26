# Ansible — Node Configuration

Configures Ubuntu 24.04 VMs after Terraform provisioning: OS hardening, package installation, K3s bootstrap, and ongoing node maintenance.

## Directory structure

```
ansible/
├── inventory/    # Host definitions and group variables
├── playbooks/    # Task orchestration
└── roles/        # Reusable, scoped configuration units
```

## What belongs here

- Inventory with all 6 nodes grouped by role (control_plane, workers)
- Playbooks for initial setup, K3s installation, and day-2 maintenance
- Roles for discrete concerns (common OS config, K3s install, Longhorn prerequisites, etc.)

## Design notes

- SSH user is `k3s` with passwordless sudo on all nodes
- SSH key pushed from both management workstations
- All playbooks must be idempotent — safe to run repeatedly
- K3s install should use the official install script with config flags matching the current cluster (embedded etcd HA, kube-vip interface, etc.)
- Swap must be disabled on all nodes (etcd latency on CP, consistency on workers)
