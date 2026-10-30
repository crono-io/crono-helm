# crono-server

![Version: 0.2.1](https://img.shields.io/badge/Version-0.2.1-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 0.1.10](https://img.shields.io/badge/AppVersion-0.1.10-informational?style=flat-square)

crono-server: the crono control plane (HTTP API, scheduler, outbox dispatcher and worker-control responders). PostgreSQL, NATS JetStream and execution workers are external to this chart.

## Install

PostgreSQL (with the crono schema applied) and NATS JetStream must already be
reachable from the cluster.

```sh
helm install crono-server oci://ghcr.io/crono-io/charts/crono-server \
  --version 0.2.1 -n crono --create-namespace \
  --set database.host=postgres.example.internal \
  --set nats.url=nats://nats.nats.svc:4222 \
  --set secret.authToken="$(openssl rand -hex 32)" \
  --set secret.databasePassword='<crono_runtime password>'
```

For production, keep credentials in an existing Secret (`existingSecret`),
pin the image by digest (`image.digest`, `requireImageDigest: true`) and use
TLS for PostgreSQL and NATS (`database.caSecret`, `nats.caSecret`).

Install [crono-web](../crono-web) with the same `ingress.host` so `/` serves
the app and `/api` reaches this chart, or install both with `crono-stack`.

## Credentials

With `existingSecret` empty the chart creates a Secret from `secret.*`;
`authToken` (32-8192 bytes) and `databasePassword` are required, plus the
NATS credential of `nats.auth.mode`. With `existingSecret` set, that Secret
must hold:

| Key | When |
|-----|------|
| `CRONO_AUTH_DEVELOPMENT_TOKEN` | always |
| `PGPASSWORD` | always |
| `nats.nkey` | `nats.auth.mode=nkey` |
| `nats.creds` | `nats.auth.mode=creds` |
| `CRONO_NATS_PASSWORD` | `nats.auth.mode=userPassword` |

## Requirements

Kubernetes: `>=1.30.0-0`

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity. |
| auth.mode | string | `"development"` | `CRONO_AUTH_MODE`. Only `development` (static bearer token) exists today. |
| autoscaling.enabled | bool | `false` | Render a HorizontalPodAutoscaler (replaces `replicaCount`). |
| autoscaling.maxReplicas | int | `6` | Maximum replicas. |
| autoscaling.minReplicas | int | `2` | Minimum replicas. |
| autoscaling.targetCPUUtilizationPercentage | int | `75` | Target average CPU utilization (percent of requests). |
| autoscaling.targetMemoryUtilizationPercentage | int | `80` | Target average memory utilization (percent of requests). |
| commonLabels | object | `{}` | Labels added to every rendered resource. |
| database.caSecret.key | string | `"ca.crt"` | Key of the CA certificate in the Secret. |
| database.caSecret.name | string | `""` | Secret holding the CA that signed the PostgreSQL server certificate; mounted at /etc/crono/postgres/ca.crt and passed as `sslrootcert`. Empty uses the built-in webpki roots. |
| database.host | string | `""` | REQUIRED. PostgreSQL host name or IP reachable from the pods. |
| database.name | string | `"crono"` | Database name. |
| database.pool.acquireTimeoutMs | int | `3000` | `CRONO_DATABASE_ACQUIRE_TIMEOUT_MS`. |
| database.pool.idleTimeoutSeconds | int | `600` | `CRONO_DATABASE_IDLE_TIMEOUT_SECONDS`. |
| database.pool.maxConnections | int | `20` | `CRONO_DATABASE_MAX_CONNECTIONS` per replica (1-200). |
| database.pool.maxLifetimeSeconds | int | `1800` | `CRONO_DATABASE_MAX_LIFETIME_SECONDS`. |
| database.pool.minConnections | int | `2` | `CRONO_DATABASE_MIN_CONNECTIONS` per replica. |
| database.port | int | `5432` | PostgreSQL port. |
| database.sslMode | string | `"verify-full"` | libpq `sslmode`: disable, allow, prefer, require, verify-ca, verify-full. |
| database.user | string | `"crono_runtime"` | Runtime role without DDL privileges. Its password comes from the `PGPASSWORD` Secret key; it is never put in the URL. |
| existingSecret | string | `""` | Existing Secret with keys `CRONO_AUTH_DEVELOPMENT_TOKEN`, `PGPASSWORD` and, depending on `nats.auth.mode`, `nats.nkey`, `nats.creds` or `CRONO_NATS_PASSWORD`. When empty the chart creates a Secret from `secret`. |
| extraEnv | list | `[]` | Extra environment variables (full EnvVar objects), e.g. `CRONO_OUTBOX_*`. |
| fullnameOverride | string | `""` | Override the full resource name (defaults to `<release>-<chart>`, or the release name when it already contains the chart name). |
| image.digest | string | `"sha256:760caa9063ec73a13a3714951b6f8c55f1ac4f209fdd66a9ffd96fa07fe5c9cc"` | Image index digest (`sha256:<64 hex>`, from the crono release notes). When set the image is pulled as `repository@digest`. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"ghcr.io/crono-io/crono-server"` | Image repository. |
| image.tag | string | chart `appVersion` | Image tag. Ignored when `digest` is set. |
| imagePullSecrets | list | `[]` | Image pull secrets (names of existing kubernetes.io/dockerconfigjson Secrets). |
| ingress.annotations | object | `{}` | Ingress annotations (e.g. `cert-manager.io/cluster-issuer`). |
| ingress.className | string | `""` | IngressClass name; empty uses the cluster default. |
| ingress.enabled | bool | `false` | Render an Ingress routing `path` on `host` to crono-server. crono-web serves `/` on the same host. `/live`, `/ready`, `/health` and `/metrics` are never routed. |
| ingress.host | string | `""` | REQUIRED when `enabled`. Public host name. |
| ingress.path | string | `"/api"` | API path prefix. |
| ingress.pathType | string | `"Prefix"` | Ingress path type. |
| ingress.tls.enabled | bool | `true` | Terminate TLS for `host`. |
| ingress.tls.secretName | string | `""` | REQUIRED when `tls.enabled`. Existing (or cert-manager managed) TLS Secret for `host`. |
| logLevel | string | `""` | `RUST_LOG` filter, e.g. `info` or `info,crono_server=debug`. Empty keeps the binary default. |
| nameOverride | string | `""` | Override the chart name used in resource names and labels. |
| nats.auth.mode | string | `"none"` | One of `none`, `nkey` (Secret key `nats.nkey`), `creds` (key `nats.creds`) or `userPassword` (`user` below plus key `CRONO_NATS_PASSWORD`). |
| nats.auth.user | string | `""` | NATS user name; required for `userPassword` mode. |
| nats.caSecret.key | string | `"ca.crt"` | Key of the CA certificate in the Secret. |
| nats.caSecret.name | string | `""` | Secret with the CA of the NATS server certificate, mounted at /etc/crono/nats/ca.crt (`CRONO_NATS_TLS_CA_FILE`). Empty uses the built-in roots. |
| nats.replicas | int | `1` | `CRONO_NATS_REPLICAS`: JetStream replication factor of the `CRONO_DISPATCH` stream (1, 3 or 5). Use 3 with a 3-node NATS cluster. |
| nats.url | string | `""` | REQUIRED. `CRONO_NATS_URL`, e.g. `nats://nats.nats.svc:4222`. A `tls://` URL forces TLS. Never embed credentials. |
| networkPolicy.dns.ports | list | `[{"port":53,"protocol":"UDP"},{"port":53,"protocol":"TCP"}]` | DNS ports allowed to `dns.to`. |
| networkPolicy.dns.to | list | `[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"kube-system"}},"podSelector":{"matchLabels":{"k8s-app":"kube-dns"}}}]` | NetworkPolicyPeers of the cluster DNS servers. |
| networkPolicy.enabled | bool | `false` | Render a default-deny networking.k8s.io/v1 NetworkPolicy. DNS egress is allowed to `networkPolicy.dns.to` on `networkPolicy.dns.ports`. |
| networkPolicy.extraEgress | list | `[]` | Raw NetworkPolicyEgressRules appended to the policy (e.g. an OTLP collector or in-cluster PostgreSQL). |
| networkPolicy.ingressFrom | list | `[]` | NetworkPolicyPeers (e.g. the Ingress controller pods) allowed to reach the server port. Empty blocks all ingress except node-local kubelet probes (allowed by most CNIs). |
| networkPolicy.metricsFrom | list | `[]` | NetworkPolicyPeers (e.g. Prometheus) allowed to scrape `/metrics` on the server port. |
| networkPolicy.nats.cidrs | list | `[]` | CIDRs of NATS servers outside the cluster. |
| networkPolicy.nats.namespaceSelector | object | `{"matchLabels":{"kubernetes.io/metadata.name":"nats"}}` | Namespace selector of the NATS server pods. |
| networkPolicy.nats.podSelector | object | `{"matchLabels":{"app.kubernetes.io/name":"nats"}}` | Pod selector of the NATS server pods. |
| networkPolicy.nats.port | int | `4222` | NATS client port. |
| networkPolicy.postgresCIDRs | list | `[]` | CIDRs of the PostgreSQL servers (egress on `database.port`). |
| nodeSelector | object | `{}` | Node selector. |
| otlpEndpoint | string | `""` | `OTEL_EXPORTER_OTLP_ENDPOINT` (gRPC). Empty disables trace export. |
| podAnnotations | object | `{}` | Pod annotations. |
| podDisruptionBudget.enabled | bool | `true` | Render a PodDisruptionBudget. Skipped when the effective replica count (`autoscaling.minReplicas` with autoscaling, else `replicaCount`) is 1, as it would block every node drain. |
| podDisruptionBudget.minAvailable | int | `1` | Minimum available pods during voluntary disruptions. |
| podLabels | object | `{}` | Extra pod labels. |
| podSecurityContext | object | `{"fsGroup":65532,"runAsGroup":65532,"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. |
| port | int | `8080` | Container port (`CRONO_SERVER_PORT`). |
| preStopSleepSeconds | int | `5` | Seconds the pod keeps serving after it is removed from endpoints, so Ingress controllers stop routing before SIGTERM starts the drain. |
| probes | object | `{"liveness":{"failureThreshold":3,"periodSeconds":10,"timeoutSeconds":2},"readiness":{"failureThreshold":3,"periodSeconds":5,"timeoutSeconds":3},"startup":{"failureThreshold":30,"periodSeconds":2,"timeoutSeconds":2}}` | Probe timings. Paths are fixed by the binary: startup and liveness use `/live`, readiness `/ready` (fails while PostgreSQL is unreachable). |
| replicaCount | int | `2` | Replicas (ignored when `autoscaling.enabled`). Every replica runs the API and the background loops; work is shared through PostgreSQL leases (`FOR UPDATE SKIP LOCKED`), so no leader election is needed. |
| requireImageDigest | bool | `false` | Fail rendering unless `image.digest` is set. Recommended for production. |
| resources | object | `{"limits":{"memory":"512Mi"},"requests":{"cpu":"100m","memory":"128Mi"}}` | Container resources. |
| secret.authToken | string | `""` | REQUIRED without `existingSecret`. API bearer token (`CRONO_AUTH_DEVELOPMENT_TOKEN`), 32-8192 bytes, e.g. `openssl rand -hex 32`. |
| secret.databasePassword | string | `""` | REQUIRED without `existingSecret`. Password of `database.user` (`PGPASSWORD`). |
| secret.natsCreds | string | `""` | Credentials file contents (key `nats.creds`); required when `nats.auth.mode` is `creds`. |
| secret.natsNkeySeed | string | `""` | NKey seed (key `nats.nkey`); required when `nats.auth.mode` is `nkey`. |
| secret.natsPassword | string | `""` | Password (key `CRONO_NATS_PASSWORD`); required when `nats.auth.mode` is `userPassword`. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true,"runAsGroup":65532,"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}}` | Container security context. |
| service.port | int | `8080` | Service port. |
| service.type | string | `"ClusterIP"` | Service type. |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations. |
| serviceAccount.create | bool | `true` | Create a dedicated ServiceAccount. Its token is never mounted: crono does not talk to the Kubernetes API. |
| serviceAccount.name | string | `""` | ServiceAccount name; defaults to the full name when empty. |
| terminationGracePeriodSeconds | int | `30` | Must exceed preStop sleep + HTTP drain + the 10 s pool close. |
| tolerations | list | `[]` | Tolerations. |
| topologySpreadConstraints | list | `[{"maxSkew":1,"topologyKey":"kubernetes.io/hostname","whenUnsatisfiable":"ScheduleAnyway"}]` | Topology spread constraints. A `labelSelector` matching the pods is added when omitted. |
