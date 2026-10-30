# crono-stack

![Version: 0.2.0](https://img.shields.io/badge/Version-0.2.0-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 0.1.9](https://img.shields.io/badge/AppVersion-0.1.9-informational?style=flat-square)

Umbrella chart for crono: crono-server (API, scheduler, dispatcher), crono-web (single-page app) and, for evaluation, a bundled single-node NATS JetStream from the official NATS chart. PostgreSQL and execution workers stay external.

| Key | Chart | Values reference |
|-----|-------|------------------|
| `server` | [crono-server](../crono-server) (alias `server`) | [crono-server README](../crono-server/README.md) |
| `web` | [crono-web](../crono-web) (alias `web`) | [crono-web README](../crono-web/README.md) |
| `nats` | official [NATS chart](https://github.com/nats-io/k8s/tree/main/helm/charts/nats) 2.15.2, disabled by default | `helm show values nats --repo https://nats-io.github.io/k8s/helm/charts/ --version 2.15.2` |

Resources are named `<release>-server`, `<release>-web` and `<release>-nats`.

## Evaluation: bundled NATS

PostgreSQL with the crono schema applied
([install guide](../../docs/install-guide.md#database-schema)) is still
required. The bundled NATS is one JetStream server without TLS or
authentication, reachable only inside the cluster:

```sh
helm install crono oci://ghcr.io/crono-io/charts/crono-stack \
  --version 0.2.0 -n crono --create-namespace \
  --set nats.enabled=true \
  --set server.nats.url=nats://crono-nats.crono.svc.cluster.local:4222 \
  --set server.database.host=postgres.example.internal \
  --set server.secret.authToken="$(openssl rand -hex 32)" \
  --set server.secret.databasePassword='<crono_runtime password>'
```

The namespace must allow the `baseline` Pod Security level: the upstream NATS
image runs as root. crono-server and crono-web satisfy `restricted`.

## Production

Leave `nats.enabled=false` and point `server.nats.url` at a separately managed
NATS JetStream cluster (TLS, NKey users, RF3). See
[docs/examples/production-stack.yaml](../../docs/examples/production-stack.yaml)
and [docs/examples/nats-jetstream-ha.yaml](../../docs/examples/nats-jetstream-ha.yaml).

## Requirements

Kubernetes: `>=1.30.0-0`

| Repository | Name | Version |
|------------|------|---------|
| file://../crono-server | server(crono-server) | 0.2.0 |
| file://../crono-web | web(crono-web) | 0.2.0 |
| https://nats-io.github.io/k8s/helm/charts/ | nats | 2.15.2 |

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| nats.config | object | single JetStream server, 10Gi PVC | Official NATS chart configuration: one JetStream server with file storage, no TLS and no authentication (reachable only inside the cluster). Keep the PVC at 8Gi or more: crono's CRONO_DISPATCH stream reserves 8 GiB (`max_bytes`) and JetStream refuses to create it in a smaller store. |
| nats.enabled | bool | `false` | Deploy a NATS server from the official chart in this release, for evaluation and single-cluster setups. Production should run a separately managed NATS JetStream cluster (docs/examples/nats-jetstream-ha.yaml). When enabled, point crono-server at it: `server.nats.url: nats://<release>-nats.<namespace>.svc.cluster.local:4222`. |
| nats.natsBox | object | `{"enabled":false}` | The interactive nats-box pod is not deployed; run it ad hoc when needed. |
| server.enabled | bool | `true` | Deploy crono-server (API, scheduler, outbox dispatcher, worker-control responders). Resources are named `<release>-server`. |
| web.enabled | bool | `true` | Deploy crono-web (the single-page app behind nginx). Resources are named `<release>-web`. |
