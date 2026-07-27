# Kubernetes Manifests and Helm Values

All Kubernetes-side configuration for the K3s cluster, organized by deployment layer.

## Directory structure

```
kubernetes/
├── bootstrap/    # Argo CD: deployed first via Helmfile, then self-manages
├── core/         # Platform infrastructure (networking, storage, ingress, certs)
├── monitoring/   # Observability stack (metrics, logs, alerting)
├── security/     # Policy enforcement, supply chain security
├── apps/         # User-facing workloads
└── ci/           # CI pipeline components
```

## How it works

Argo CD is the reconciler for the Helm-managed components; the raw-manifest ones are still being migrated (see current state below). Each component directory contains:

- `values.yaml`: Helm values for the chart (hand-authored, intent-based)
- Argo CD `Application` manifest: where to find the chart and which values to use
- `network-policy.yaml`: NetworkPolicy for the component, co-located with the workload it protects
- Raw manifests where applicable (kube-vip static pod, MetalLB config)

Helmfile is the bootstrap/break-glass tool. `helmfile.yaml` at the repo root references the same values files. Used to:

1. Stand up the cluster before Argo CD exists
2. Emergency manual deploys if Argo CD is down

## Deployment order

The layers deploy in sequence, each depending on the one above:

1. **bootstrap/**: Argo CD (manages everything below)
2. **core/**: kube-vip → MetalLB → Longhorn → cert-manager → ingress-nginx
3. **monitoring/**: kube-prometheus-stack → Loki
4. **security/**: Kyverno, Harbor
5. **apps/**: Hugo portfolio site
6. **ci/**: CI pipeline

> **Current migration state:** Argo CD manages cert-manager (2026-04-29), ingress-nginx (2026-07-25), and kube-prometheus-stack (2026-07-26). Helmfile manages only `argocd`. MetalLB, Longhorn, and kube-vip are still kubectl/static-pod. The layout above is the GitOps target, migrated to incrementally.

## Secrets

Sensitive values are encrypted with SOPS + age. Encrypted files use the `.sops.yaml` suffix convention (e.g. `secrets.sops.yaml`). The `.sops.yaml` config at the repo root defines encryption rules.
