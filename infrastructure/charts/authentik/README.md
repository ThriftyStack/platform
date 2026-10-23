# Authentik runtime (management cluster)

Helm wrapper around the official Authentik chart. Identity objects stay in
`ThriftyStack/controlplane`. See ADR-0007.

## Secrets

Create `authentik-credentials` in namespace `authentik` before the first sync:

```sh
kubectl create namespace authentik --dry-run=client -o yaml | kubectl apply -f -
PG_PASS="$(openssl rand -base64 36)"
SECRET_KEY="$(openssl rand -base64 60)"
kubectl -n authentik create secret generic authentik-credentials \
  --from-literal=AUTHENTIK_SECRET_KEY="$SECRET_KEY" \
  --from-literal=AUTHENTIK_POSTGRESQL__HOST=authentik-postgresql \
  --from-literal=AUTHENTIK_POSTGRESQL__USER=authentik \
  --from-literal=AUTHENTIK_POSTGRESQL__NAME=authentik \
  --from-literal=AUTHENTIK_POSTGRESQL__PASSWORD="$PG_PASS" \
  --from-literal=postgresql-password="$PG_PASS"
```

Also seed management Vault `infra/authentik` (and clients) for the Crossplane
Workspace; mirror `secret_key` / `pg_password` there for recovery.

## Exposure

Server Service is NodePort `30080` (HTTP). Cloudflare tunnel origin:

`http://10.0.10.101:30080` with `http_host_header = auth.devoops.uk`.
