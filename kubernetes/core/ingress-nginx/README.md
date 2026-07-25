# ingress-nginx

Ingress controller providing HTTP/HTTPS routing to cluster services.

## What belongs here

- `values.yaml` — Helm chart values
- `bootstrap/argocd/applications/` — Argo CD Application CRD

## Design notes

- Current version: app v1.14.1 (chart 4.14.1), installed via Helm
- Chart: `ingress-nginx/ingress-nginx` from `https://kubernetes.github.io/ingress-nginx`
- Gets a LoadBalancer IP from MetalLB — depends on MetalLB being deployed first
- Runs 2 replicas with a worker nodeSelector and topology spread (see values.yaml)
- TLS termination uses certs from cert-manager
