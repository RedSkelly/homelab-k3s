# cert-manager

Automates TLS certificate issuance and renewal via ACME or self-signed CAs.

## What belongs here

- `values.yaml` — Helm chart values
- `application.yaml` — Argo CD Application CRD
- `clusterissuer.yaml` — ClusterIssuer CRs (Let's Encrypt staging/prod, or self-signed)
- `secrets.sops.yaml` — SOPS-encrypted ACME credentials (if using DNS-01 challenge)

## Design notes

- Current version: v1.19.2, managed by Argo CD (migrated from Helmfile 2026-04-29)
- Chart: `jetstack/cert-manager` from `https://charts.jetstack.io`
- CRDs are installed with the chart (`installCRDs: true`)
- Certs auto-renew (90-day duration, renewal ~30 days before expiry)
- ClusterIssuer resources go here alongside the chart values — they're tightly coupled to cert-manager's lifecycle
