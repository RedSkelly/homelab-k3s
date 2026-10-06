# ADR 0001: Service load balancer and ingress controller

## Status

Proposed, 2026-10-06. Covers the current service load balancer and ingress setup, why each k3s default was replaced, and the proposed target state. Migration steps are out of scope.

## Current state

Verified 2026-10-06 with kubectl, SSH to each server, and nslookup.

- k3s v1.34.3+k3s1 on all six nodes. The three servers (10.0.10.50-52) pass `--disable traefik` and `--disable servicelb` as flags in `k3s.service`; `/etc/rancher/k3s/config.yaml` disables only `local-storage`.
- No `svclb-*` pods or DaemonSets in any namespace. No HelmChart or HelmChartConfig in `kube-system`.
- MetalLB v0.14.5 (controller and speaker) in L2 mode: IPAddressPool `homelab-pool` is `10.0.10.200-10.0.10.202` with auto-assign on, announced by L2Advertisement `homelab-l2`. No BGPAdvertisement.
- ingress-nginx controller v1.14.1 (two pods), chart 4.14.1, deployed by the Argo CD Application `ingress-nginx`. Its Service `ingress-nginx-controller` holds 10.0.10.200 and is the only LoadBalancer Service in the cluster.
- IngressClass `nginx` (not marked default) serves five Ingresses, `argocd`, `longhorn`, `grafana`, `alertmanager`, and `prometheus`, each under `.homelab.local` at 10.0.10.200. `grafana.homelab.local` resolves to 10.0.10.200 from a workstation via the tailnet resolver.
- kube-vip v0.8.2 runs as a DaemonSet on the three control-plane nodes, not as a static pod. It holds the API VIP 10.0.10.49 (`cp_enable=true`); `svc_enable` is unset, so it does not answer LoadBalancer Services.

## Why the k3s defaults were replaced

The original reasons were not recorded. Both below were reconstructed on 2026-10-06.

- ServiceLB, replaced by MetalLB (reconstructed; still holds). ServiceLB has no address pool: it runs a hostPort DaemonSet per LoadBalancer Service and publishes node IPs [1]. The OPNsense Unbound host overrides for `*.homelab.local` need one IP that survives a node drain; MetalLB L2 assigns a pool IP and moves it by ARP when the announcing node fails.
- Traefik, replaced by ingress-nginx (reconstructed). No evaluated comparison is on record; ingress-nginx was the common default in k3s build guides when the cluster was built. Disabling the bundled Traefik is still required for any self-managed controller, because the bundled chart version follows the k3s release and cannot be pinned in Git.

## Upstream change

- Kubernetes retired ingress-nginx in March 2026: no further releases, bug fixes, or security patches. Existing deployments keep working [2][3].
- The final releases were announced on 2026-03-13 as controller v1.15.0, v1.14.4, and v1.13.8 [4]. GitHub lists one later round on 2026-03-19 (v1.15.1, v1.14.5, v1.13.9) and shows the repository archived read-only on 2026-03-24 [5].
- The running v1.14.1 (released 2025-12-05) predates the archive and is four patch releases behind v1.14.5, the last release on its line. Vulnerabilities reported after end of life will not be patched [4].
- Exposure, per network design and not tested for this record: LAN and tailnet only. The CGNAT WAN has no inbound path, and CLIENT_LAN is blocked from VLAN 10.

## Proposed target state

- Service load balancer: keep MetalLB and `--disable servicelb`. kube-vip stays control-plane VIP only.
- Ingress: keep `--disable traefik`. Replace ingress-nginx with Traefik v3 from its upstream Helm chart, deployed as an Argo CD Application with the chart version pinned in Git. Traefik serves Ingress and Gateway API resources concurrently, so routes can move to Gateway API one at a time.
- Alternative considered: Envoy Gateway. It supports Gateway API only, so each Ingress must be converted before it can move.

## Sequencing

- After the off-node etcd snapshot and age key backup items.
- Before NetworkPolicy default-deny and Kyverno, because their allow rules reference the ingress controller's namespace and labels.
- Before any public exposure (the Hugo site via Cloudflare Tunnel).

## References

1. k3s docs, Networking Services: https://docs.k3s.io/networking/networking-services
2. Kubernetes blog, ingress-nginx retirement announcement (2025-11-11): https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/
3. Kubernetes blog, Steering and Security Response Committees statement (2026-01-29): https://kubernetes.io/blog/2026/01/29/ingress-nginx-statement/
4. Kubernetes dev list, final releases announcement (2026-03-13): https://groups.google.com/a/kubernetes.io/g/dev/c/sBte4y6-r3o/m/ELep7tBoCgAJ
5. GitHub, kubernetes/ingress-nginx (archive status, release tags): https://github.com/kubernetes/ingress-nginx
