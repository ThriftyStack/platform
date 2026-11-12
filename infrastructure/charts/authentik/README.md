# Authentik runtime (management cluster)

Helm wrapper around the official Authentik chart. Identity objects stay in
`ThriftyStack/crossplane`. See ADR-0007.

File storage is a Longhorn PVC mounted at `/data` (Authentik keeps uploads
under `/data/media`). A nightly CronJob writes an age-encrypted `pg_dump -Fc`
and a tar of `/data` to MinIO. The job does not delete objects. The bucket
lifecycle is the retention policy.

Anything already stored only on the server container disk is ephemeral. The
first rollout that mounts the empty PVC drops those files. Re-upload icons
and other files if any were created before this volume existed.

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

The backup reads that Secret by name. It uses `AUTHENTIK_POSTGRESQL__HOST`,
`AUTHENTIK_POSTGRESQL__USER`, `AUTHENTIK_POSTGRESQL__NAME`, and
`AUTHENTIK_POSTGRESQL__PASSWORD`. It does not mount `AUTHENTIK_SECRET_KEY`.

## Media

`authentik-data` is a 10Gi Longhorn PVC, `ReadWriteOnce`, mounted at `/data`
on the server and the worker through `global.volumes` and
`global.volumeMounts`. The container user is uid 1000, so both pods set
`fsGroup: 1000`.

Longhorn RWO attaches to one node. The worker's required pod affinity follows
the server pod onto that node, and server and worker use `Recreate` so a
rollout drops the old pod before the new one mounts the volume. Both
strategies set `rollingUpdate: null`. Server-side apply keeps an omitted
`rollingUpdate`, and a `Recreate` Deployment that still has one is rejected.
The backup pod uses the same affinity and mounts the claim read-only.

The chart's soft anti-affinity preset prefers a different node. The worker
replaces that preset. With one replica of each, both pods and the backup pod
must land on the server pod's node.

## Backup

`backup.enabled` defaults to true. Schedule is `15 3 * * *` (03:15 UTC).
`concurrencyPolicy` is `Forbid`.

`backup.ageRecipient` is the offline age public key. The dump container
still exits before `pg_dump` if that value is put back to `age1REPLACE_ME`.
The private identity stays off the cluster except during a restore test.

Backup and restore-test pods meet the restricted Pod Security profile, including
a Job created from either CronJob. The pod runs as uid/gid 1000 with `fsGroup:
1000`, `runAsNonRoot`, and `seccompProfile: RuntimeDefault`. Every container
sets `allowPrivilegeEscalation: false`, drops all capabilities, and uses a
read-only root filesystem with an emptyDir at `/tmp`.

`postgres:17.10-bookworm`, `jauderho/age:v1.3.2`, and `amazon/aws-cli:2.39.3`
ship with no `USER`, so they start as root unless the pod sets one. `pg_dump`,
`pg_restore`, and the AWS CLI are world-executable and run as uid 1000, which
is the media volume owner and the owner of the mode 0600 files on `/work`.
The age binary is mode 0755 and uses that same uid so it can read those files.
The AWS containers set `HOME` and `TMPDIR` to `/tmp`. The throwaway Postgres
sidecar overrides to uid/gid 999, the `postgres` user in that image, and mounts
emptyDirs on its data directory and `/var/run/postgresql`.

Each successful run uploads one prefix:

```txt
authentik-backups/mgmt/<YYYYMMDDTHHMMSSZ>/
  authentik.dump.age
  data.tar.gz.age
  manifest.env.age
  SHA256SUMS
  COMPLETE
```

`COMPLETE` is uploaded last. Ignore a prefix that has no `COMPLETE`.
`data.tar.gz.age` is the `/data` tree. `pg_dump -Fc` is transaction-consistent.
The tar is crash-consistent: Authentik may be writing files while tar runs, and
tar treats a changed file as success.

MinIO is `https://s3.adminio.biz:9000`, region `eu-poznan-1`, path-style.
Credentials come from ExternalSecret `authentik-backup-minio`. This chart
creates a namespaced SecretStore `oke-vault` in `authentik`. It does not
create a ClusterSecretStore, and the management AppProject does not need a
new cluster rule. ADR-0008 still keeps SecretStores out of the secrets stage.

The store talks to estate Vault at `https://vault.devoops.uk`, KV v2 mount
`infra`, auth mount `jwt-management`, role `authentik_authentik-eso`
(underscore: `vault/management_jwt.tf` derives that from
`authentik/authentik-eso`), audience `vault-oke`. The token is minted for
ServiceAccount `authentik-eso`. A Role in `authentik` lets the External
Secrets controller ServiceAccount `external-secrets` in namespace
`external-secrets` create that token and no other.

The remote key is `authentik/backup-minio`. The mount is already `infra`, so
the API path is `infra/data/authentik/backup-minio`, which matches the role
policy `infra/data/authentik` and `infra/data/authentik/*`. A key of
`infra/authentik/backup-minio` would look up the mount twice.

```sh
vault kv put -mount=infra authentik/backup-minio \
  accessKey='<writer-key>' \
  secretKey='<writer-secret>'
```

Use a credential that can write objects and cannot delete them. The bucket
already has Object Lock GOVERNANCE for 30 days and an expiration rule. Do
not commit those values.

ConfigMap `oke-vault-listener-ca` holds the public listener chain as key
`ca.crt`: DevOops Issuing CA E1, then DevOops Root CA R1. E1 is issued by
R1 and expires 2031-09-05. R1 is self-signed and expires 2036-09-03. The
render check rejects `PLACEHOLDER`, a private key, a non-PEM, or any chain
whose subjects are not those two names. `vault.devoops.uk` presents a leaf
for `CN=vault.internal` issued by E1, so this bundle is what the store uses
to verify that leaf.

Images are pinned: `postgres:17.10-bookworm` (same tag as the bundled
database), `jauderho/age:v1.3.2` (upstream age publishes no image; the binary
is the age CLI), and `amazon/aws-cli:2.39.3`.

## Restore

Run this on a workstation that has `age`, `aws`, and a Postgres 17 client.
Use a read credential for the bucket, not the backup writer. Keep the age
identity offline and only on this workstation for the duration of the restore.

```sh
export AWS_ACCESS_KEY_ID='<restore-reader-key>'
export AWS_SECRET_ACCESS_KEY='<restore-reader-secret>'
export AWS_DEFAULT_REGION='eu-poznan-1'
export AWS_CONFIG_FILE="$(mktemp)"
cat > "$AWS_CONFIG_FILE" <<'EOF'
[default]
s3 =
    addressing_style = path
EOF
ENDPOINT='https://s3.adminio.biz:9000'
BUCKET='authentik-backups'
PREFIX='mgmt/<YYYYMMDDTHHMMSSZ>'

aws --endpoint-url "$ENDPOINT" s3api head-object \
  --bucket "$BUCKET" --key "$PREFIX/COMPLETE"
RESTORE_DIR="$(mktemp -d "/var/tmp/authentik-restore.XXXXXX")"
aws --endpoint-url "$ENDPOINT" s3 cp \
  "s3://$BUCKET/$PREFIX/" "$RESTORE_DIR/" --recursive --only-show-errors
test -f "$RESTORE_DIR/COMPLETE"
(cd "$RESTORE_DIR" && sha256sum -c SHA256SUMS)

age -d -i /path/to/authentik-backup.agekey \
  "$RESTORE_DIR/manifest.env.age"
age -d -i /path/to/authentik-backup.agekey \
  "$RESTORE_DIR/authentik.dump.age" | pg_restore --list >/dev/null
age -d -i /path/to/authentik-backup.agekey \
  "$RESTORE_DIR/data.tar.gz.age" | tar -tzf - >/dev/null
```

Restore into a scratch database before touching the live one. Match
`postgresql_major` from the manifest (17 for this chart):

```sh
createdb -U postgres authentik_scratch
age -d -i /path/to/authentik-backup.agekey \
  "$RESTORE_DIR/authentik.dump.age" \
  | pg_restore -d authentik_scratch --no-owner --exit-on-error
psql -d authentik_scratch -c 'SELECT count(*) FROM django_migrations'
psql -d authentik_scratch -c 'SELECT count(*) FROM authentik_core_user'
```

`django_migrations` must be greater than zero. `authentik_core_user` must be
a number. Drop `authentik_scratch` when the check is done.

To replace the live database, scale the server and worker to zero first so
they stop writing. Keep Postgres up. Take a pre-restore `pg_dump -Fc` of the
current `authentik` database. Then `dropdb` / `createdb` and `pg_restore` the
decrypted dump with `--no-owner --exit-on-error`. Extract `data.tar.gz` onto
the `authentik-data` volume at `/data` (a one-off pod with the same server
affinity, run as uid 1000). Scale the server and worker back to one. Sign in
with the break-glass admin and check MFA plus one OIDC client before treating
the restore as finished.

Remove the age identity and the reader credentials from the workstation when
you are done.

## Monthly restore test

CronJob `authentik-backup-restore-test` is suspended (`30 4 1 * *` does not
fire). It downloads the newest `mgmt/` prefix that has `COMPLETE`, checks
`SHA256SUMS`, decrypts the dump, and restores it into a Postgres 17 container
in the same pod (emptyDir, password `restore-test`, not the estate database).
Postgres is a native sidecar: it stays up for the restore, and the kubelet
stops it when the restore container exits so the Job can complete. The job
prints `authentik_core_user` and fails unless `django_migrations` is at least 1.

Once a month, after at least one prefix has `COMPLETE`:

```sh
kubectl -n authentik create secret generic authentik-backup-age-identity \
  --from-file=identity=/path/to/authentik-backup.agekey
kubectl -n authentik create job authentik-restore-test-manual \
  --from=cronjob/authentik-backup-restore-test
kubectl -n authentik logs job/authentik-restore-test-manual -c restore
kubectl -n authentik delete job authentik-restore-test-manual
kubectl -n authentik delete secret authentik-backup-age-identity
```

Do not leave `authentik-backup-age-identity` in the namespace. Do not
unsuspend the CronJob. The private key is only for this manual Job.

## Exposure

Server Service is NodePort `30080` (HTTP). Cloudflare tunnel origin:

`http://10.0.10.101:30080` with `http_host_header = auth.devoops.uk`.
