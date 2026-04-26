# ingress-nginx

Ingress controller providing HTTP/HTTPS routing to cluster services.

## What belongs here

- `values.yaml` — Helm chart values
- `application.yaml` — Argo CD Application CRD

## Design notes

- Current version: v4.14.1, installed via Helm (3 revisions)
- Chart: `ingress-nginx/ingress-nginx` from `https://kubernetes.github.io/ingress-nginx`
- Gets a LoadBalancer IP from MetalLB — depends on MetalLB being deployed first
- Single replica is sufficient for homelab scale
- TLS termination uses certs from cert-manager
