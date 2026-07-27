# ingress-nginx

Ingress controller providing HTTP/HTTPS routing to cluster services.

## What belongs here

- `values.yaml`: Helm chart values
- `bootstrap/argocd/applications/`: Argo CD Application CRD

## Design notes

- Current version: app v1.14.1 (chart 4.14.1), managed by Argo CD (migrated from Helmfile 2026-07-25)
- The Application is multi-source: it references `values.yaml` in this directory by path via a `$values` source-ref, so this file stays the single source of truth
- Chart: `ingress-nginx/ingress-nginx` from `https://kubernetes.github.io/ingress-nginx`
- Gets a LoadBalancer IP from MetalLB, so MetalLB must be deployed first
- Runs 2 replicas with a worker nodeSelector and topology spread (see values.yaml)
- TLS termination uses certs from cert-manager
