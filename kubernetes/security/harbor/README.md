# Harbor + Trivy

Private container registry with integrated vulnerability scanning.

## What belongs here

- `values.yaml` — Helm chart values for Harbor (Trivy is embedded)
- `application.yaml` — Argo CD Application CRD

## Design notes

- **Roadmap item #5** — not yet implemented, depends on custom images existing
- Chart: `harbor/harbor` from `https://helm.goharbor.io`
- Trivy scanner is built into Harbor — no separate deployment needed
- Storage backend should use Longhorn PVCs for registry blobs and database
- Resource-intensive — evaluate cluster headroom before deploying
- Requires a TLS cert (from cert-manager) and an Ingress for the UI/API
- Image pull secrets will need to be distributed to namespaces (or use a Kyverno mutating policy)
