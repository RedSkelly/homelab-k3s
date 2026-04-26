# Ansible Playbooks

## What belongs here

Playbooks that orchestrate roles against inventory groups. Each playbook should do one thing well.

## Planned playbooks

| Playbook               | Purpose                                               |
|------------------------|-------------------------------------------------------|
| `site.yml`             | Full cluster setup — runs all roles in order           |
| `common.yml`           | OS-level config (packages, sysctl, swap, NTP)          |
| `k3s-install.yml`      | K3s installation and join (CP first, then workers)     |
| `k3s-upgrade.yml`      | Rolling K3s upgrade respecting drain/etcd sequencing   |
| `reboot.yml`           | Rolling reboot with Longhorn health gates              |

## Sequencing rules

- CP nodes: cordon → verify etcd → reboot → uncordon → verify etcd → next
- Worker nodes: drain → reboot → uncordon → verify Longhorn healthy → next
- Never reboot more than one CP node at a time
