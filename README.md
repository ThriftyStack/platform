# Platform GitOps

This repository is the **platform** Argo CD source: cluster profiles, staged infrastructure Applications, hub/spoke roots, and reviewed access projects.

Workload Helm charts live in a separate repository: [`sudoceohq/applications`](https://github.com/sudoceohq/applications).

| Repository | Owns |
|------------|------|
| `sudoceohq/platform` (this repo) | `infrastructure/`, `charts/cluster-apps`, `clusters/`, promotion/validation ops |
| `sudoceohq/applications` | Workload charts under `charts/<name>/` and per-cluster values under `clusters/<id>/` |

## Layout

| Path | Purpose |
|------|---------|
| `infrastructure/charts/` | Vendored platform Helm wrappers |
| `infrastructure/configuration/` | Vault provider/PKI, mesh policy and qualification |
| `charts/cluster-apps/` | Staged Application rendering for a cluster |
| `clusters/<id>/` | Platform identity, stage flags, and infrastructure overrides only |
| `ops/` | Offline contracts, promotion and PKI handoff helpers |

## Access boundary

- Spoke **platform** AppProjects (`spokeProjects`) may source only this repository.
- Workload AppProjects (`workloadProjects`) may source only `fleet.applicationsRepository`, destination approved workload namespaces, and grant no cluster-scoped resources. They must not destination the hub `argocd` namespace.
- Adding a chart in the applications repository does not enroll it; enable a reviewed workload AppProject and Application first.

## Validation

```sh
python3 ops/fetch-dependencies.py /path/to/public-cache
CHART_CACHE=/path/to/public-cache HELM=/path/to/helm ruby ops/check.rb
```

Bootstrap installs Argo CD and the management root; see the sibling `bootstrap` checkout for cluster bring-up, Vault/PKI runbooks and recovery.
