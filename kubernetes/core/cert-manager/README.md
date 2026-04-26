# cert-manager

Automates TLS certificate issuance and renewal via ACME or self-signed CAs.

## What belongs here

- `values.yaml` — Helm chart values
- `application.yaml` — Argo CD Application CRD
- `clusterissuer.yaml` — ClusterIssuer CRs (Let's Encrypt staging/prod, or self-signed)
- `secrets.sops.yaml` — SOPS-encrypted ACME credentials (if using DNS-01 challenge)

## Design notes

- Current version: v1.19.2, installed via Helm (1 revision)
- Chart: `jetstack/cert-manager` from `https://charts.jetstack.io`
- CRDs are installed with the chart (`installCRDs: true`)
- Current certs expire June 2026
- ClusterIssuer resources go here alongside the chart values — they're tightly coupled to cert-manager's lifecycle
