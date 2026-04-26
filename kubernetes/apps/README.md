# Applications

User-facing workloads deployed via the full GitOps pipeline. These represent the "top of the stack" — everything in `core/`, `monitoring/`, and `security/` exists to support these.

## What belongs here

Each application gets its own subdirectory containing:

- Helm values, Kustomize overlays, or raw manifests
- An Argo CD `Application` CRD
- SOPS-encrypted secrets (if needed)

## Current applications

| Application      | Purpose                          | Status  |
|------------------|----------------------------------|---------|
| Hugo portfolio   | Static portfolio site via GitOps | Planned |
