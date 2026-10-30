# crono installation guide

Step-by-step installation of crono with the charts in this repository. Two
profiles:

- **Evaluation**: `crono-stack` with the bundled single-node NATS, a
  chart-created Secret and your PostgreSQL. Minutes to set up; no TLS to NATS,
  no worker isolation.
- **Production**: external PostgreSQL over TLS, a separately managed 3-server
  NATS JetStream cluster with TLS and NKey users, pre-created Secrets,
  digest-pinned images, Ingress and NetworkPolicies, external workers.

Examples use release `crono` in namespace `crono`, and NATS release `nats` in
namespace `nats`. Day-2 topics (workers, NATS backups, network policy, DR)
are in [operations.md](operations.md).

## Prerequisites

| Requirement | Notes |
|---|---|
| Kubernetes 1.30+ | native `preStop.sleep`; at least 3 schedulable nodes for the HA NATS cluster |
| Helm 3.8+ | OCI registry support |
| PostgreSQL 16+ | reachable from the pods; TLS strongly recommended; administrator access once per release to apply the schema |
| `psql` 16+ | on the host that applies the schema |
| NATS 2.10+ with JetStream | bundled (evaluation) or separately managed ([NATS](#nats)) |
| Ingress controller | optional; one host serves `/` (crono-web) and `/api` (crono-server) |
| NetworkPolicy-enforcing CNI | optional, for `networkPolicy.enabled` |
| `nk` | NKey tool (`go install github.com/nats-io/nkeys/nk@latest` or the `natsio/nats-box` image), production only |

Pod Security: crono-server and crono-web satisfy `restricted`. The upstream
NATS image runs as root and shares its process namespace with the config
reloader, so a namespace running NATS needs `baseline` (warn/audit
`restricted`):

```sh
kubectl create namespace crono
kubectl label namespace crono pod-security.kubernetes.io/enforce=restricted   # production (NATS elsewhere)
# evaluation with bundled NATS instead:
# kubectl label namespace crono pod-security.kubernetes.io/enforce=baseline pod-security.kubernetes.io/warn=restricted
```

**Images.** The charts deploy crono `appVersion` (0.1.9) by default, which
must be published at `ghcr.io/crono-io/crono-{server,web}` before a default
install can pull. Releases before 0.1.9 support neither NATS TLS/NKeys nor
PostgreSQL TLS; pin them only for evaluation (`server.nats.auth.mode: none`,
`server.database.sslMode: disable`). Look up digests with:

```sh
docker buildx imagetools inspect ghcr.io/crono-io/crono-server:0.1.9 --format '{{json .Manifest.Digest}}'
docker buildx imagetools inspect ghcr.io/crono-io/crono-web:0.1.9 --format '{{json .Manifest.Digest}}'
```

## Database schema

crono-server never changes the schema: its runtime role (`crono_runtime`) has
no DDL privileges. An operator applies the SQL of the crono release **before**
deploying that release's images. It is not a Helm hook on purpose:
`00_init.sql` needs an administrator with `CREATEROLE` and `CREATEDB`, uses
psql meta-commands (`\ir`, `\gexec`) and runs `SET ROLE crono_owner` (a
`NOLOGIN` role); a hook would put administrator credentials into the cluster.
The SQL is idempotent (`IF NOT EXISTS`, an advisory lock around the role
step); the schema is still a draft without numbered migrations. Only one
operator applies it at a time.

```sh
# From a host that reaches PostgreSQL, with psql >= 16 and the server's CA file.
export ADMIN_URL='postgres://<admin>@<host>:5432/postgres?sslmode=verify-full&sslrootcert=./postgres-ca.crt'
export PGPASSWORD='<admin password>'          # or ~/.pgpass; keep it out of shell history

# 1. Check out the crono release tag (bare version) matching the images.
git clone https://github.com/crono-io/crono && git -C crono checkout 0.1.9

# 2. Runtime password (used only when crono_runtime is created the first time).
umask 077
openssl rand -hex 32 | tr -d '\n' > crono_runtime.password

# 3. Apply the bootstrap and schema: database `crono`, roles crono_owner
#    (NOLOGIN, owns objects) and crono_runtime (LOGIN, DML only).
psql "$ADMIN_URL" -v ON_ERROR_STOP=1 \
  -v crono_runtime_password="$(cat crono_runtime.password)" \
  -f crono/db/sql/00_init.sql

# 4. Verify ownership, role safety and grants.
psql "$ADMIN_URL" -v ON_ERROR_STOP=1 -f crono/db/sql/check.sql
```

If step 3 or 4 fails, stop: do not deploy the new images. Re-running the same
release's SQL is safe. The schema has no down-migrations: rolling images back
after a schema change is only safe if the older server accepts the newer
schema (check the release notes).

**Connection settings.** The chart builds `CRONO_DATABASE_URL` from
`server.database.*` and never puts the password in it (sqlx reads
`PGPASSWORD` from the Secret):

```
postgres://crono_runtime@<host>:5432/crono?sslmode=verify-full&sslrootcert=/etc/crono/postgres/ca.crt
```

`sslMode` defaults to `verify-full`: `server.database.host` must match a SAN
of the server certificate. Set `server.database.caSecret.name` for a private
CA; empty uses the built-in public (webpki) roots.

**Pool sizing.** Each replica keeps its own pool. Keep
`(replicaCount + 1 surge pod) x pool.maxConnections + other clients` below
PostgreSQL `max_connections - superuser_reserved_connections`; the defaults (2
replicas, 20 connections) need up to 60.

## Secrets

Never commit secret material. Work in a private temporary directory:

```sh
S=$(mktemp -d) && cd "$S" && umask 077      # rm -rf "$S" when done
```

### crono-server credentials

Two options:

- **Chart-created** (`server.existingSecret: ""`, default): pass
  `server.secret.authToken` (32 to 8192 bytes), `server.secret.databasePassword`
  and the NATS credential of `server.nats.auth.mode` (`natsNkeySeed`,
  `natsCreds` or `natsPassword`). The values end up in the Helm release
  (stored as a Secret), so prefer `--set-file` over shell history and prefer
  the next option in production.
- **Pre-created** (`server.existingSecret: crono-server`):

```sh
openssl rand -hex 32 | tr -d '\n' > dev-token                # API bearer token
cp /path/to/crono_runtime.password .                         # from "Database schema"
nk -gen user > crono-server.nk                               # NATS identity (seed)
nk -inkey crono-server.nk -pubout                            # public key -> NATS users (next section)

kubectl -n crono create secret generic crono-server \
  --from-file=CRONO_AUTH_DEVELOPMENT_TOKEN=dev-token \
  --from-file=PGPASSWORD=crono_runtime.password \
  --from-file=nats.nkey=crono-server.nk
```

| Key | When | Picked up without restart? |
|---|---|---|
| `CRONO_AUTH_DEVELOPMENT_TOKEN` | always | no: `rollout restart` |
| `PGPASSWORD` | always | no: `rollout restart` |
| `nats.nkey` | `nats.auth.mode: nkey` (mounted at `/etc/crono/nats/nkey.seed`) | yes, at the next reconnect |
| `nats.creds` | `nats.auth.mode: creds` | yes, at the next reconnect |
| `CRONO_NATS_PASSWORD` | `nats.auth.mode: userPassword` (with `nats.auth.user`) | no |

Keep `dev-token` in your password manager: API clients and the web app need
it. Authentication is development-token only today
(`server.auth.mode: development`).

### CA Secrets for crono-server

```sh
kubectl -n crono create secret generic crono-postgres-ca --from-file=ca.crt=./postgres-ca.crt
kubectl -n crono create secret generic nats-ca --from-file=ca.crt=./nats-ca.crt
```

Reference them with `server.database.caSecret.name` and
`server.nats.caSecret.name`. CA and credential files are mounted through a
projected volume without `subPath`, so rotated Secrets reach running pods.

### NATS server TLS

Use cert-manager or a private CA. With OpenSSL (ECDSA P-256; replace the
external name and LoadBalancer IP):

```sh
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 3650 \
  -subj '/CN=crono NATS CA' -keyout nats-ca.key -out nats-ca.crt   # keep nats-ca.key offline

cat > nats-server.ext <<'EOF'
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = DNS:nats, DNS:nats.nats, DNS:nats.nats.svc, DNS:nats.nats.svc.cluster.local, DNS:*.nats-headless, DNS:*.nats-headless.nats, DNS:*.nats-headless.nats.svc, DNS:*.nats-headless.nats.svc.cluster.local, DNS:nats.example.com, DNS:localhost, IP:192.0.2.10
EOF
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -subj '/CN=nats.nats.svc.cluster.local' -keyout nats-server.key -out nats-server.csr
openssl x509 -req -in nats-server.csr -CA nats-ca.crt -CAkey nats-ca.key -CAcreateserial \
  -days 397 -extfile nats-server.ext -out nats-server.crt
openssl verify -CAfile nats-ca.crt nats-server.crt

kubectl create namespace nats
kubectl label namespace nats pod-security.kubernetes.io/enforce=baseline pod-security.kubernetes.io/warn=restricted
kubectl -n nats create secret tls nats-server-tls --cert=nats-server.crt --key=nats-server.key
kubectl -n nats create secret generic nats-ca --from-file=ca.crt=nats-ca.crt
```

The same certificate serves clients (4222) and mutually authenticated routes
(6222), hence both `serverAuth` and `clientAuth`. SANs:

| SAN | Why |
|---|---|
| `nats`, `nats.nats`, `nats.nats.svc`, `nats.nats.svc.cluster.local` | in-cluster clients (crono-server uses the last) |
| `*.nats-headless.nats.svc.cluster.local` (required), shorter `*.nats-headless*` forms (optional) | routes dial `nats-<n>.nats-headless.nats.svc.cluster.local`; some TLS stacks reject single-label wildcards |
| external DNS name and LoadBalancer IP | workers outside the cluster |
| `localhost` | `kubectl port-forward` maintenance |

With cert-manager, add a `Certificate` through the NATS chart's
`extraResources` that writes `nats-server-tls` with the same usages and SANs;
the config reloader applies renewals without restarts.

### Ingress certificate

With cert-manager, set `cert-manager.io/cluster-issuer` in
`server.ingress.annotations`/`web.ingress.annotations`; otherwise:

```sh
kubectl -n crono create secret tls crono-tls --cert=crono.crt --key=crono.key
```

## NATS

crono uses one NATS account for the `CRONO_DISPATCH` JetStream stream
(work-queue retention, file storage) and the request/reply subjects between
workers and servers (`crono.worker.*`). crono-server creates or updates the
stream at startup with `CRONO_NATS_REPLICAS` (`server.nats.replicas`) and
`max_bytes` of 8 GiB, so every JetStream server needs a file store (PVC /
`max_file_store`) of at least 8Gi; smaller stores refuse to create the stream
and `/health` reports `"nats": "degraded"`.

| Option | When | crono-server values |
|---|---|---|
| Bundled (`nats.enabled: true`) | evaluation, single cluster, in-cluster clients only | `nats.url: nats://<release>-nats.<ns>.svc.cluster.local:4222`, `replicas: 1`, `auth.mode: none` |
| Separately managed HA cluster ([example values](examples/nats-jetstream-ha.yaml)) | production | `nats.url: tls://nats.nats.svc.cluster.local:4222`, `replicas: 3`, `caSecret`, `auth.mode: nkey` |
| Existing NATS deployment or hosted NATS | you already operate NATS | JetStream enabled, an account with the permissions in [operations.md](operations.md#nats-users-and-permissions); `creds` or `nkey` auth |

Install the HA cluster (after the Secrets above and replacing every `REPLACE`
value: storage class, public NKeys of crono-server, the ops identity and each
worker):

```sh
helm upgrade --install nats nats --repo https://nats-io.github.io/k8s/helm/charts/ \
  --version 2.15.2 -n nats -f docs/examples/nats-jetstream-ha.yaml --wait --timeout 15m
# Workers outside the cluster: add
#   --set service.merge.spec.type=LoadBalancer --set service.merge.spec.externalTrafficPolicy=Local
kubectl -n nats get pods,pvc,svc       # 3/3 pods, 3 Bound 20Gi PVCs
kubectl -n nats exec nats-0 -c nats -- wget -qO- 'http://localhost:8222/healthz?js-enabled-only=true'
```

Keep the release name `nats`: SANs, selectors and the URL above assume it,
and the upstream chart does not quote the instance label (a YAML-ambiguous
release name such as `n` fails to render).

## Install

**Evaluation** (bundled NATS, chart-created Secret):

```sh
helm install crono oci://ghcr.io/crono-io/charts/crono-stack --version 0.2.1 \
  -n crono --create-namespace \
  --set nats.enabled=true \
  --set server.nats.url=nats://crono-nats.crono.svc.cluster.local:4222 \
  --set server.database.host=postgres.example.internal \
  --set-file server.secret.authToken=dev-token \
  --set-file server.secret.databasePassword=crono_runtime.password \
  --wait
```

Add `--set server.database.sslMode=require` (or `disable`) only for test
databases without a verifiable certificate.

**Production**: copy [examples/production-stack.yaml](examples/production-stack.yaml),
replace every `REPLACE` value (digests, hosts, CIDRs), then:

```sh
helm upgrade --install crono oci://ghcr.io/crono-io/charts/crono-stack --version 0.2.1 \
  -n crono -f production-stack.yaml --wait --timeout 10m
```

The schema rejects unknown keys and missing required values; with
`requireImageDigest: true` rendering fails unless every image has a
`sha256:` digest.

**From a checkout** (unreleased chart changes):

```sh
helm repo add nats https://nats-io.github.io/k8s/helm/charts/ --force-update
helm dependency build charts/crono-stack
helm upgrade --install crono charts/crono-stack -n crono -f production-stack.yaml --wait
```

## Verify

```sh
helm -n crono status crono
kubectl -n crono rollout status deploy/crono-server
kubectl -n crono rollout status deploy/crono-web
kubectl -n crono port-forward svc/crono-server 8080:8080 &
curl -s localhost:8080/ready                          # 200 while PostgreSQL answers
curl -s localhost:8080/health | jq '{database, nats}'  # both "available"
curl -s -H "Authorization: Bearer $(cat dev-token)" localhost:8080/api/queues
curl -sI https://crono.example.com/                   # crono-web through the Ingress
```

`/live`, `/ready`, `/health` and `/metrics` are never routed by the Ingress
(only `/api` is). With RF3, `nats stream info CRONO_DISPATCH` must show three
current replicas ([operations](operations.md#the-nats-cli)). Then connect the
workers ([operations](operations.md#external-workers)).

## Upgrade

**New crono release:**

1. Read the release notes.
2. Apply the release's schema ([Database schema](#database-schema)). Never skip it: it is idempotent.
3. Update `server.image.{tag,digest}` and `web.image.{tag,digest}`, then
   `helm upgrade` with the same values file (staging first).
4. [Verify](#verify); upgrade the workers' `crono-worker` package to the same
   release, host by host.

Rollouts surge one pod at a time (`maxUnavailable: 0`), so an image that does
not start leaves the previous version serving.

**New chart version:** read the changelog below, render the diff
(`helm template` old vs new with your values, or the helm-diff plugin), then
`helm upgrade`. Pod templates carry no chart-version label, so chart-only
upgrades do not restart pods.

**NATS chart:** read the chart's `UPGRADING.md` and the server release notes,
move one minor version at a time, compare renders, and watch
`kubectl -n nats rollout status statefulset/nats` plus the stream replicas
after each pod. Users and TLS changes are hot-reloaded without restarts.

### From chart `crono` 0.1.0 to `crono-stack` 0.2.0

The single `crono` chart was split into `crono-server`, `crono-web` and the
`crono-stack` umbrella. Values moved and several defaults changed:

| 0.1.0 | 0.2.0 |
|---|---|
| `server.*` / `web.*` in chart `crono` | same keys under `server.*` / `web.*` of `crono-stack` (or top level of the component charts) |
| `server.image.digest` required by the schema | optional; `image.tag` defaults to `appVersion`; set `requireImageDigest: true` to enforce digests |
| `server.existingSecret: crono-server` | `""`: the chart creates `<release>-server` from `server.secret.*` unless you set `existingSecret` |
| `server.nats.url` default `tls://nats.nats.svc.cluster.local:4222` | required, no default |
| `server.nats.replicas: 3`, `auth.mode: nkey`, `caSecret.name: nats-ca` | `1`, `none`, `""` (set them explicitly for an HA NATS cluster) |
| `server.database.caSecret.name: crono-postgres-ca` | `""` (public roots); set it for a private CA |
| `nodeSelector: {workload: platform}` | `{}` |
| `server.pdb` / `web.pdb` | `podDisruptionBudget` |
| one `ingress` block with `/api` and `/` | `server.ingress` (path `/api`) and `web.ingress` (path `/`) with the same host |
| CNI-specific network policy (`networkPolicy.ingressController`, `prometheus`, `natsNamespace`, `extraServerEgress`) | standard NetworkPolicy per component: `ingressFrom`, `metricsFrom`, `postgresCIDRs`, `nats.{namespaceSelector,podSelector,cidrs,port}`, `extraEgress` |
| — | HPA (`autoscaling.*`), bundled evaluation NATS (`nats.enabled`) |

Deployment selectors changed (`app.kubernetes.io/name` is now `server` /
`web`), so the release cannot be upgraded in place. Plan a short API outage
(dispatches wait safely in the PostgreSQL outbox; workers reconnect):

```sh
helm -n crono get values crono > old-values.yaml       # translate with the table above
helm -n crono uninstall crono
helm install crono oci://ghcr.io/crono-io/charts/crono-stack --version 0.2.1 \
  -n crono -f new-values.yaml --wait
```

## Rollback

```sh
helm -n crono history crono
helm -n crono rollback crono <revision> --wait
```

Rolling images back is safe when the older server works with the newer
schema (additive changes); otherwise restore the database together with the
image rollback ([operations](operations.md#disaster-recovery)).

## Uninstall

```sh
helm -n crono uninstall crono
kubectl -n crono delete secret crono-server crono-postgres-ca nats-ca crono-tls --ignore-not-found
# Bundled NATS keeps its PersistentVolumeClaim after uninstall; delete it to drop the stream:
kubectl -n crono delete pvc crono-nats-js-crono-nats-0
```

The database, the separately managed NATS release and the workers are not
touched.
