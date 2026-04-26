# Ansible Inventory

## What belongs here

- `hosts.yml` — inventory file defining all 6 K3s nodes with connection details
- `group_vars/` — variables scoped to node groups (all, control_plane, workers)
- `host_vars/` — variables scoped to individual nodes (if needed)

## Groups

| Group           | Hosts                                          |
|-----------------|------------------------------------------------|
| `control_plane` | k3s-cp-01 / 02 / 03 on VLAN 10  |
| `workers`       | k3s-wk-01 / 02 / 03 on VLAN 10  |
| `k3s_cluster`   | All 6 nodes (parent group)                     |

## Connection defaults

- `ansible_user: k3s`
- `ansible_ssh_private_key_file: ~/.ssh/<key_name>`
- `ansible_become: true`
