# Platform GitOps

This repository is the **platform** Argo CD source: cluster profiles, staged infrastructure Applications, hub/spoke roots, and reviewed access projects.

Workload Helm charts live in a separate repository: [`ThriftyStack/applications`](https://github.com/ThriftyStack/applications).

| Repository | Owns |
|------------|------|
| `ThriftyStack/platform` (this repo) | `infrastructure/`, `charts/cluster-apps`, `clusters/`, promotion/validation ops |
| `ThriftyStack/applications` | Workload charts under `charts/<name>/` and per-cluster values under `clusters/<id>/` |

## Layout

| Path | Purpose |
|------|---------|
| `infrastructure/charts/` | Vendored platform Helm wrappers (includes management NetBird agents) |
| `infrastructure/configuration/` | Vault provider/PKI, mesh policy and qualification |
| `charts/cluster-apps/` | Staged Application rendering for a cluster |
| `clusters/<id>/` | Platform identity, stage flags, and infrastructure overrides only |
| `ops/` | Offline contracts, ceremony status/promotion and PKI handoff helpers |
| `Makefile` | Day-2 operator entrypoints (`status`, `promote-pr`, mesh verify, offline `check`) |

## Day-0 vs Day-2

| Boundary | Where | Examples |
|----------|-------|----------|
| Day-0 (human / out of band) | Sibling [`bootstrap`](../bootstrap) `vault/` | `prepare.sh`, `vault operator init`, `bootstrap-auth.sh`, recovery shares |
| Day-2 (GitOps ceremony) | This repo `ops/` + `Makefile` | `make status`, `make promote-pr STAGE=...`, `pki-sign` / `pki-trust`, `verify-mesh` |

Promotion never auto-merges, never force-pushes, and never calls Argo sync APIs. After a human merges the promote PR, Argo reconciles from `main`. Day-0 Vault bring-up remains documented in [`bootstrap/VAULT-PKI.md`](../bootstrap/VAULT-PKI.md).

## Ceremony Makefile

Set `KUBE_CONTEXT` explicitly (or `cluster.context`). The context API must match `clusters/<id>/cluster.yaml` `operatorServer`.

```sh
export KUBE_CONTEXT=admin@management
make status
make promote-pr STAGE=enrollment   # live gates → branch → gh pr create
make promote STAGE=enrollment      # local values.yaml flip only (no push)
make pki-sign
make pki-trust
make verify-mesh-renewal           # ~70m natural renewal evidence
make verify-mesh                   # STRICT / enrollment checks
```

`make promote-pr` reuses the same live gates as `ops/promote.rb`, commits only `clusters/<id>/values.yaml`, and opens a GitHub PR for human review.

## Self-hosted ceremony runner

Live gates need reachability to the private management API VIP (`operatorServer`). GitHub-hosted runners cannot do that.

1. Register a self-hosted runner with labels `self-hosted` and `thrifty-management` on a host that can reach the VIP.
2. Add repository secret `KUBECONFIG` with the protected operator kubeconfig contents.
3. Dispatch [`.github/workflows/ceremony-promote.yaml`](.github/workflows/ceremony-promote.yaml) with `cluster`, `stage`, and `kube_context`.
4. Rotate the kubeconfig secret when credentials change; do not store Vault root tokens, ADC keys, or listener private keys in Actions.

Until the runner exists, use local `make promote-pr` (same scripts). Offline PR validation remains [`.github/workflows/validate.yaml`](.github/workflows/validate.yaml) on `ubuntu-24.04` and does not touch the cluster.

## Access boundary

- Spoke **platform** AppProjects (`spokeProjects`) may source only this repository.
- Workload AppProjects (`workloadProjects`) may source only `fleet.applicationsRepository`, destination approved workload namespaces, and grant no cluster-scoped resources. They must not destination the hub `argocd` namespace.
- Adding a chart in the applications repository does not enroll it; enable a reviewed workload AppProject and Application first.

## Validation

```sh
python3 ops/fetch-dependencies.py /path/to/public-cache
CHART_CACHE=/path/to/public-cache HELM=/path/to/helm make check
```

Bootstrap installs Argo CD and the management root; see the sibling `bootstrap` checkout for cluster bring-up, Vault/PKI runbooks and recovery.
