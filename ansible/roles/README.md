# Ansible Roles

## What belongs here

Reusable roles following standard Ansible role structure (`tasks/`, `handlers/`, `templates/`, `defaults/`, `vars/`).

## Planned roles

| Role          | Scope                                                      |
|---------------|------------------------------------------------------------|
| `common`      | Package installs, sysctl tuning, swap disable, NTP, SSH hardening |
| `k3s_server`  | K3s control plane install (embedded etcd, kube-vip flags)  |
| `k3s_agent`   | K3s worker join                                            |
| `longhorn`    | Longhorn prerequisites (open-iscsi, nfs-common, mount propagation) |

## Design notes

- Each role must be idempotent
- Roles should not assume execution order — use playbooks for orchestration
- Keep roles scoped to a single concern
