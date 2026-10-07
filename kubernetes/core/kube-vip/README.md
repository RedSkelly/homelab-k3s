# kube-vip

Provides the API server VIP `10.0.10.49` by ARP. Runs as a DaemonSet, one pod per control plane node.

## Current state

Not in Git. k3s applies the DaemonSet from `/var/lib/rancher/k3s/server/manifests/kube-vip.yaml` on a server node (AddOn `kube-vip`); which servers hold the file has not been checked. Target ownership: `docs/adr/0002-kube-vip-ownership.md`.

## Settings

Read from the live DaemonSet on 2026-10-06. A rebuild recreates kube-vip from these values.

| Setting                      | Value                                    | Why                                              |
|------------------------------|------------------------------------------|--------------------------------------------------|
| Image                        | `ghcr.io/kube-vip/kube-vip:v0.8.2`       |                                                  |
| `address` / `vip_cidr`       | `10.0.10.49` / `32`                      | Listed in each server's `tls-san`                |
| `vip_interface`              | `enp6s18`                                | VLAN 10 node interface                           |
| `vip_arp`                    | `true`                                   | L2 announcement; no BGP peer exists              |
| `cp_enable` / `cp_namespace` | `true` / `kube-system`                   |                                                  |
| `vip_leaderelection`         | `true`                                   | One holder at a time, Lease `plndr-cp-lock`      |
| `svc_enable`                 | unset                                    | MetalLB owns LoadBalancer Services (ADR 0001)    |
| Placement                    | nodeSelector `node-role.kubernetes.io/control-plane=true`, tolerates its `NoSchedule` taint | |
| Pod                          | `hostNetwork`, adds `NET_ADMIN` and `NET_RAW`, args `["manager"]` | Binds the VIP on the host interface and sends ARP |
| RBAC                         | ServiceAccount, ClusterRole, and ClusterRoleBinding all named `kube-vip` | |

The ClusterRole grants get/list/watch/update/patch on `services`, `endpoints`, `nodes`, and `pods`, and get/list/watch/create/update/patch on `coordination.k8s.io` `leases`.
