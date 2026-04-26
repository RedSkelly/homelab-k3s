# CI Pipeline

In-cluster CI for building and testing workloads.

## What belongs here

- Helm values or manifests for the chosen CI engine
- `application.yaml` — Argo CD Application CRD
- Pipeline definitions (Tekton Pipelines/Tasks or Gitea Actions workflows)

## Design notes

- **Roadmap item #2** — tool choice is TBD (Tekton vs Gitea Actions Runner)
- **Tekton:** cloud-native, Kubernetes-native pipelines — more complex but portfolio-impressive
- **Gitea Actions:** simpler, GitHub Actions-compatible — lower overhead if Gitea is the Git host
- Primary use case is building the Hugo portfolio container image
- The CI engine must be able to push images to Harbor (when deployed) or an external registry
