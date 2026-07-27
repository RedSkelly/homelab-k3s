# Argo CD

GitOps reconciler, chosen over Flux for demo-ability and UI.

## What belongs here

- `values.yaml`: Helm values for the Argo CD chart
- `application.yaml`: Argo CD Application CRD for self-management
- `app-of-apps.yaml`: Root Application or ApplicationSet that discovers all component directories

## Chart

- **Chart:** `argo/argo-cd` (from `https://argoproj.github.io/argo-helm`)
- **Namespace:** `argocd`

## Design notes

- **Current state:** deployed (non-HA, chart 9.5.9, app v3.3.8); manages cert-manager, ingress-nginx, and kube-prometheus-stack, with app-of-apps expansion pending
- Argo CD is bootstrapped via Helmfile, then manages its own upgrades
- The app-of-apps pattern allows each component directory to define its own Application manifest
- Argo CD watches this Git repo and reconciles cluster state to match
- Tune replica counts and resource requests for homelab scale
- Consider enabling the ApplicationSet controller for dynamic app discovery across directories
