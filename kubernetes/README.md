# Kubernetes Manifests and Helm Values

All Kubernetes-side configuration for the K3s cluster, organized by deployment layer.

## Directory structure

```
kubernetes/
├── bootstrap/    # Argo CD — deployed first via Helmfile, then self-manages
├── core/         # Platform infrastructure (networking, storage, ingress, certs)
├── monitoring/   # Observability stack (metrics, logs, alerting)
├── security/     # Policy enforcement, supply chain security
├── apps/         # User-facing workloads
└── ci/           # CI pipeline components
```

## How it works

**Argo CD is the primary reconciler.** Each component directory contains:

- `values.yaml` — Helm values for the chart (hand-authored, intent-based)
- Argo CD `Application` manifest — tells Argo CD where to find the chart and which values to use
- `network-policy.yaml` — NetworkPolicy for the component (co-located with the workload it protects)
- Raw manifests where applicable (kube-vip static pod, MetalLB config)

**Helmfile is the bootstrap/break-glass tool.** A top-level `helmfile.yaml` in this directory references the same values files. Used to:

1. Stand up the cluster before Argo CD exists
2. Emergency manual deploys if Argo CD is down

## Deployment order

The layers deploy in sequence — each depends on the one above:

1. **bootstrap/** — Argo CD (manages everything below)
2. **core/** — kube-vip → MetalLB → Longhorn → cert-manager → ingress-nginx
3. **monitoring/** — kube-prometheus-stack → Loki
4. **security/** — Kyverno, Harbor
5. **apps/** — Hugo portfolio site
6. **ci/** — CI pipeline

## Secrets

Sensitive values are encrypted with SOPS + age. Encrypted files use the `.sops.yaml` suffix convention (e.g., `secrets.sops.yaml`). The `.sops.yaml` config at the repo root defines encryption rules.
