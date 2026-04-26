# Hugo Portfolio Site

Static portfolio site deployed via the full GitOps chain — the capstone workload that demonstrates every platform layer working together.

## What belongs here

- `deployment.yaml` — Deployment, Service, Ingress (or Helm values if using a chart)
- `application.yaml` — Argo CD Application CRD
- `secrets.sops.yaml` — SOPS-encrypted secrets (Cloudflare Tunnel credentials, etc.)

## Design notes

- **Roadmap item #7** — the final workload in the sequence
- Exposed externally via Cloudflare Tunnel (no public IP needed)
- Hugo builds happen in CI (Tekton or Gitea Actions), producing a container image
- The container image is served by a lightweight web server (nginx or Caddy)
- If Harbor is deployed, the image is pushed there; otherwise, use an external registry
- This workload exercises every layer: GitOps, CI, Ingress, TLS, monitoring, policy
