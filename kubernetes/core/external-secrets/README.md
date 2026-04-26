# Vault + External Secrets Operator

Centralized secrets management — replaces SOPS+age when the use case outgrows file-based encryption.

## What belongs here

- `vault/values.yaml` — HashiCorp Vault Helm values
- `eso/values.yaml` — External Secrets Operator Helm values
- `application.yaml` — Argo CD Application CRDs (one per chart)
- `secretstore.yaml` — ClusterSecretStore CR pointing to Vault

## Design notes

- **Roadmap item #6** — not yet implemented
- Current secrets approach is SOPS + age (file-level encryption in Git)
- Migrate to Vault + ESO when managing secrets across multiple namespaces or teams becomes unwieldy
- Vault should run in HA mode (3 replicas on CP nodes, or use integrated storage)
- Resource-intensive — evaluate whether the homelab has headroom before deploying
