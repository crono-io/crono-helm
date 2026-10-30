# crono operations runbook

Day-2 operations for crono installed with these charts: architecture and
availability, external workers, NATS (permissions, HA, backups), network
policy, credential rotation, disaster recovery and chart releases. Installation
is in [install-guide.md](install-guide.md). Examples use release `crono` in
namespace `crono` and NATS release `nats` in namespace `nats`.

## Architecture

| Component | Where | Kind | Replicas | State |
|---|---|---|---|---|
| `crono-server` | cluster | Deployment (`crono-server` chart) | 2 | none (PostgreSQL) |
| `crono-web` | cluster | Deployment (`crono-web` chart) | 2 | none |
| NATS JetStream | cluster, separately managed (or bundled for evaluation) | StatefulSet (official `nats` chart) | 3 (1 bundled) | PVC per server |
| PostgreSQL | outside the charts | managed service or VMs | n/a | source of truth |
| `crono-worker` | outside the cluster | systemd service (`crono-worker` package) | any | none |

**crono-server** is one binary serving the HTTP API and running the
scheduler, the transactional-outbox dispatcher, the reconciler and the NATS
worker-control responders. Every replica runs every loop without leader
election: work is claimed in PostgreSQL with `FOR UPDATE SKIP LOCKED` and
leases, and worker requests reach replicas through NATS queue groups, so each
request is handled by exactly one replica.

**crono-web** is a static bundle served by unprivileged nginx. The browser
calls `/api` on the same origin and the Ingress routes that prefix to
crono-server; nginx returns 404 for `/api`, so a misrouted Ingress fails
visibly.

**Durability.** A Run, its first Attempt and an outbox row are written in one
PostgreSQL transaction; the dispatcher marks a Run queued only after JetStream
acknowledged the message. Losing NATS delays dispatch but does not lose work.

| From | To | Port | Protocol |
|---|---|---|---|
| Browser / CLI | Ingress | 443 | HTTPS, one host |
| Ingress | crono-server / crono-web | 8080 | HTTP (`/api` / everything else) |
| crono-server | PostgreSQL | 5432 | TLS (`verify-full`), password via `PGPASSWORD` |
| crono-server | NATS | 4222 | TLS + NKey |
| Workers | NATS (LoadBalancer or NodePort) | 4222 | TLS + NKey |
| NATS | NATS | 6222 | mutual TLS routes |
| kubelet, Prometheus | crono-server | 8080 | `/live`, `/ready`, `/metrics` |
| kubelet, Prometheus | NATS | 8222 | monitoring, never published |

### Health, shutdown and availability

| Probe | crono-server | crono-web |
|---|---|---|
| startup | `GET /live` every 2 s, up to 60 s | n/a |
| liveness | `GET /live` | `GET /healthz` |
| readiness | `GET /ready` (fails while PostgreSQL is unreachable) | `GET /healthz` |

Readiness depends on PostgreSQL only: a NATS outage degrades `/health`
(`"nats": "degraded"`) but keeps the API available because dispatches wait in
the outbox.

Graceful shutdown: the pod leaves the Service endpoints and `preStop.sleep`
waits `preStopSleepSeconds` (5 s) so Ingress controllers stop routing; then
SIGTERM drains HTTP connections, stops the loops and closes the pool (bounded
at 10 s) within `terminationGracePeriodSeconds` (30 s). The sleep action is
native (Kubernetes 1.30+); the distroless image has no shell.

HA semantics:

- 2 replicas per Deployment, `RollingUpdate` with `maxUnavailable: 0` and
  `maxSurge: 1`: a new pod must be ready before an old one stops, so a broken
  image never removes capacity.
- `PodDisruptionBudget` `minAvailable: 1` per Deployment, rendered only with
  more than one replica (`replicaCount`, or `autoscaling.minReplicas` with
  the HPA) so a single pod never blocks node drains; topology spread on
  `kubernetes.io/hostname` (`ScheduleAnyway`). Use `nodeSelector`,
  `tolerations` and `affinity` to place pods on dedicated nodes.
- Optional HPA (`autoscaling.enabled`); every replica adds a full database
  pool, so size PostgreSQL first.
- NATS keeps the upstream PDB (`maxUnavailable: 1`), preserving the JetStream
  quorum; required pod anti-affinity puts the 3 servers on 3 nodes.

## External workers

Workers run on VMs or bare-metal hosts outside the cluster and talk only to
NATS (never to PostgreSQL), over TLS, with one NKey identity per worker whose
permissions only allow that worker's ID and Queue.

How a worker talks to crono:

1. It resolves its Queue name to the Queue UUID
   (`crono.worker.queue.resolve.<name>`, answered by a crono-server replica).
2. It ensures the durable pull consumer `crono-<Queue UUID>` on
   `CRONO_DISPATCH`, filtered on `crono.dispatch.<Queue UUID>`.
3. It sends presence heartbeats every 10 s (`crono.worker.presence.<worker ID>`),
   pulls dispatches, claims each one (`crono.worker.control.claim.<worker ID>`),
   executes it, streams bounded output (`crono.worker.output.<worker ID>`)
   and reports the result.

The server rejects requests whose subject and payload worker IDs differ, and
the NATS permissions stop a worker from using any other ID. **Every worker
needs a fixed `CRONO_WORKER_ID`** (the package default derives a fresh,
hostname-based ID per process, which per-worker permissions would reject).

Connectivity prerequisites:

- the worker host reaches the NATS client port: expose the NATS Service as a
  `LoadBalancer` (or `NodePort`) with `externalTrafficPolicy: Local`, which
  preserves worker source IPs for firewalls and network policies; with
  `Local`, only nodes running a NATS pod answer;
- a DNS name for that address listed in the NATS certificate SANs;
- the `crono-worker` package of the same crono release as the server.

### Onboarding a worker

Example: worker `build-01` serving Queue `default`.

```sh
# 1. Queue UUID
curl -fsS -H "Authorization: Bearer $CRONO_TOKEN" https://crono.example.com/api/queues \
  | jq -r '.items[] | "\(.name) \(.id)"'

# 2. Key pair on the worker host, so the seed never leaves it
sudo install -d -m 0750 -o root -g crono /etc/crono/nats
sudo sh -c 'umask 027; nk -gen user > /etc/crono/nats/nkey.seed'
sudo chgrp crono /etc/crono/nats/nkey.seed
sudo nk -inkey /etc/crono/nats/nkey.seed -pubout      # prints U...; send only this
```

3. Add a user entry to the NATS values
   (`config.merge.accounts.CRONO.users`, see
   [nats-jetstream-ha.yaml](examples/nats-jetstream-ha.yaml)) with the worker
   permissions below, and `helm upgrade` the NATS release. The config reloader
   applies it without restarts:
   `kubectl -n nats logs nats-0 -c nats --since=5m | grep -i reload`.
4. Install the NATS CA as `/etc/crono/nats/ca.crt` (mode 0644).
5. Configure `/etc/crono/worker.env` (mode 0640, `root:crono`):

```sh
CRONO_NATS_URL=tls://nats.example.com:4222
CRONO_NATS_TLS_CA_FILE=/etc/crono/nats/ca.crt
CRONO_NATS_NKEY_SEED_FILE=/etc/crono/nats/nkey.seed
CRONO_WORKER_ID=build-01
CRONO_WORKER_QUEUE=default
CRONO_WORKER_CONCURRENCY=8
```

Exactly one NATS identity may be configured (NKey seed, `.creds` file, or user
and password). Never put credentials in `CRONO_NATS_URL`.

6. `sudo systemctl enable --now crono-worker.service` and
   `journalctl -u crono-worker -f` (expect "Crono worker started"). The worker
   appears in the presence views within one heartbeat, and
   `nats consumer info CRONO_DISPATCH crono-<Q>` shows the consumer. A
   `Permissions Violation` in the worker or NATS log names the subject the
   user entry is missing (usually a wrong worker ID or Queue UUID).

Workers on the same Queue share the durable consumer `crono-<Q>` (dispatches
are load-balanced) but each needs its own user entry. A worker serves one
Queue; renaming a Queue keeps its UUID.

**Rotation:** the seed file is re-read on every reconnect. Add the new public
key as an additional user with the same permissions, upgrade NATS, switch the
worker's seed file and restart it, then remove the old entry.
**Revocation:** remove the user entry and upgrade NATS; reloaded servers
close that user's connections immediately. Dispatches the worker held are
redelivered after their ack wait (90 s) to other workers of the Queue,
subject to the server's lease checks.

Jobs run as the same `crono` user as the worker and can read its seed; jobs
are trusted code by design, otherwise run them under another user.

## NATS users and permissions

Every client authenticates with an NKey: the server configuration holds only
public keys (`U...`), each client holds its seed (`SU...`). Accounts:
`system_account: SYS`, `CRONO` with JetStream.

| User | Publish allow | Subscribe allow |
|---|---|---|
| crono-server (shared by all replicas) | `crono.>`, `$JS.API.>`, `$JS.ACK.>`, `_INBOX.>` | `crono.worker.>`, `_INBOX.>` |
| crono-ops (backups, inspection) | `$JS.API.>`, `$JS.SNAPSHOT.>`, `_INBOX.>` | `_INBOX.>` |
| one per worker (`<W>` worker ID, `<Q>` Queue UUID) | `crono.worker.control.*.<W>`, `crono.worker.presence.<W>`, `crono.worker.output.<W>`, `crono.worker.queue.resolve.*`, `$JS.API.INFO`, `$JS.API.STREAM.INFO.CRONO_DISPATCH`, `$JS.API.CONSUMER.INFO.CRONO_DISPATCH.crono-<Q>`, `$JS.API.CONSUMER.CREATE.CRONO_DISPATCH.crono-<Q>.crono.dispatch.<Q>`, `$JS.API.CONSUMER.MSG.NEXT.CRONO_DISPATCH.crono-<Q>`, `$JS.ACK.CRONO_DISPATCH.crono-<Q>.>` | `_INBOX.>` |

Because the consumer-create subject embeds the filter, a worker cannot create
a consumer that reads another Queue; the server repeats the worker ID in every
subject and validates it against the payload, and the permissions make the
subject itself unforgeable. The per-worker set still allows resolving any
Queue name to its UUID, which reveals names and IDs only.

### Risk: `_INBOX.>`

Workers must subscribe to `_INBOX.>` to receive replies and pulled messages,
and NATS cannot restrict that to "my own inbox" while every client uses the
default `_INBOX.` prefix. A compromised worker can observe replies addressed
to other clients (claim responses with execution snapshots, messages pulled
by other workers); it cannot publish on their behalf. Treat worker hosts as
trusted. The complete fix is a per-worker inbox prefix (`_INBOX_<W>.>`), which
needs a crono change; separate accounts per worker with service imports are
the heavier alternative.

## NATS high availability

- **3 servers**, routes on 6222 through the headless Service, dialled by FQDN,
  mutual TLS (`verify: true`).
- **JetStream file storage** on one PVC per server (20Gi in the example, at
  least 8Gi: `CRONO_DISPATCH` reserves 8 GiB); local SSD volumes are
  preferred because JetStream replicates itself.
- **RF3:** `server.nats.replicas: 3` makes crono-server create or update
  `CRONO_DISPATCH` with three replicas, which keeps accepting writes while one
  server is down.
- **Placement:** required pod anti-affinity on the hostname plus spread on
  hostname and zone; three eligible nodes are required.
- **Graceful restarts:** lame-duck mode (10 s grace, 30 s duration) moves
  clients to other servers before a pod stops.
- **External access:** only port 4222 is published. LoadBalancer with
  `externalTrafficPolicy: Local`, or NodePort:

```yaml
service:
  merge:
    spec:
      type: NodePort
      externalTrafficPolicy: Local
  patch:
    - op: add
      path: /spec/ports/0/nodePort
      value: 30422
```

### Monitoring

```sh
kubectl -n nats port-forward pod/nats-0 8222:8222 &
curl -s 'localhost:8222/healthz?js-enabled-only=true'
curl -s 'localhost:8222/jsz?accounts=true&streams=true&consumers=true' | jq '.account_details[]?.stream_detail[]? | {name, cluster, state}'
curl -s localhost:8222/routez | jq '.num_routes'          # 2 per server
```

For Prometheus, enable the chart's exporter and, with the Prometheus Operator,
its PodMonitor (`promExporter.enabled: true`, port 7777, plus
`promExporter.podMonitor.enabled: true`; extra labels via
`promExporter.podMonitor.merge`). A top-level `podMonitor` key is ignored by
the chart. Alert on:
fewer than 3 ready NATS pods; a stream replica not current or without leader;
PVC usage above 80%; consumer `num_pending` growing while workers are online;
crono `/health` reporting `"nats": "degraded"`.

### The `nats` CLI

Use the crono-ops identity from a workstation, through a port-forward (the
certificate includes `localhost`) or the external address:

```sh
kubectl -n nats port-forward svc/nats 4222:4222 &
nats context save crono-ops --server tls://localhost:4222 --tlsca ./nats-ca.crt --nkey ./crono-ops.nk
nats --context crono-ops stream info CRONO_DISPATCH    # Replicas: 3, leader + 2 current
nats --context crono-ops consumer ls CRONO_DISPATCH    # one durable crono-<Queue UUID> per Queue
```

Server-level reports need a `SYS` account user; add one temporarily.

### Backup and restore

PostgreSQL is the source of truth: every dispatch exists in the outbox before
it is published, and a worker's claim is checked against the authoritative
Attempt state. A NATS backup preserves in-flight dispatches and consumer
state, which shortens recovery; it does not replace PostgreSQL backups.

```sh
# Online, consistent backup including consumers (older CLIs: nats stream backup)
nats --context crono-ops backup stream CRONO_DISPATCH ./nats-backup/CRONO_DISPATCH-$(date +%F)
# Restore (the stream must not exist; older CLIs: nats stream restore)
nats --context crono-ops stream rm CRONO_DISPATCH -f
nats --context crono-ops backup restore stream ./nats-backup/CRONO_DISPATCH-2026-10-30
```

After a restore, restart the workers (they re-attach to their durable
consumers) and `kubectl -n crono rollout restart deploy/crono-server` so the
stream configuration (RF3) is re-applied. Starting empty is acceptable when no
backup exists: crono-server recreates the stream and workers recreate their
consumers on restart.

**Node and volume loss** with node-bound volumes: replace the lost server's
PVC and pod; the new pod starts empty and JetStream re-replicates the RF3
stream. PVC protection keeps a claim until no pod uses it, so request its
deletion without waiting, then delete the pod:

```sh
kubectl -n nats delete pvc nats-js-nats-2 --wait=false   # Terminating while nats-2 exists
kubectl -n nats delete pod nats-2                         # releases it; the StatefulSet recreates both
# The new claim: Bound and not the terminating old one.
until kubectl -n nats get pvc nats-js-nats-2 \
  -o jsonpath='{.metadata.deletionTimestamp} {.status.phase}' 2>/dev/null | grep -qx ' Bound'; do sleep 5; done
kubectl -n nats wait --for=condition=Ready pod/nats-2 --timeout=10m
nats --context crono-ops stream info CRONO_DISPATCH       # Replicas: leader + 2 current
```

If the new pod stays `Pending` because its claim "is being deleted", delete
pod `nats-2` once more after the old PVC is gone. When the node is
unreachable the old pod stays `Terminating`: fence the node first (power it
off or detach it from the network, then `kubectl delete node`), and only then
`kubectl -n nats delete pod nats-2 --grace-period=0 --force`; force-deleting a
pod on a partitioned node can leave the old server running beside its
replacement. Wait until `nats stream info` shows the replica current before
touching another server; never delete two PVCs at once.

## Network policy

With `networkPolicy.enabled: true` each component renders a default-deny
`networking.k8s.io/v1` NetworkPolicy; every rule is an explicit allowance:

| Pod | Direction | Peer | Port |
|---|---|---|---|
| crono-server | ingress | `networkPolicy.ingressFrom` (Ingress controller) | 8080 |
| crono-server | ingress | `networkPolicy.metricsFrom` (Prometheus) | 8080 |
| crono-server | egress | `networkPolicy.dns.to` (kube-dns in kube-system) | `networkPolicy.dns.ports` (53 UDP/TCP) |
| crono-server | egress | `networkPolicy.postgresCIDRs` | `database.port` |
| crono-server | egress | `networkPolicy.nats.{namespaceSelector,podSelector,cidrs}` | `networkPolicy.nats.port` (4222) |
| crono-server | egress | `networkPolicy.extraEgress` (e.g. OTLP collector) | as written |
| crono-web | ingress | `networkPolicy.ingressFrom` | 8080 |
| crono-web | egress | `networkPolicy.dns.to` (kube-dns in kube-system) | `networkPolicy.dns.ports` (53 UDP/TCP) |
| crono-web | egress | `networkPolicy.extraEgress` | as written |

The DNS peer defaults to the kube-dns/CoreDNS pods (`k8s-app: kube-dns` in
`kube-system`). Clusters whose DNS pods carry other labels, or that run
NodeLocal DNSCache (pods resolve through the node-local `169.254.20.10`), need
their own peers; the list replaces the default:

```yaml
server:
  networkPolicy:
    dns:
      to:
        - ipBlock:
            cidr: 169.254.20.10/32   # NodeLocal DNSCache
        - namespaceSelector:          # kube-dns, used when the cache is down
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
web:
  networkPolicy:
    dns:
      to:
        - ipBlock:
            cidr: 169.254.20.10/32
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
```

The NATS selectors default to namespace `nats` and `app.kubernetes.io/name:
nats`. For the bundled NATS, select the release namespace; for NATS outside
the cluster set both selectors to `null` (an empty map merges with the
defaults instead of clearing them) and list its addresses in
`networkPolicy.nats.cidrs`. Kubelet probes are node-local and allowed by most
CNIs. Example for an OTLP collector:

```yaml
server:
  networkPolicy:
    extraEgress:
      - to:
          - namespaceSelector:
              matchLabels:
                kubernetes.io/metadata.name: observability
        ports:
          - port: 4317
            protocol: TCP
```

Protect NATS the same way in its namespace: allow 4222 from crono-server pods
and the worker networks (source IPs are preserved by
`externalTrafficPolicy: Local`), 6222 between NATS pods, 8222/7777 from
monitoring. Verify end to end with `curl localhost:8080/health` through a
port-forward: both `database` and `nats` must be `available`.

## Credential rotation

| Secret | Procedure |
|---|---|
| Development token | Update `CRONO_AUTH_DEVELOPMENT_TOKEN`, `kubectl -n crono rollout restart deploy/crono-server`, update clients. |
| `PGPASSWORD` | See below. |
| crono-server NKey | Add the new public key as a second crono-server user, upgrade NATS, replace `nats.nkey` (picked up at the next reconnect; restart to force it), remove the old user. |
| Worker NKeys | [External workers](#external-workers). |
| NATS server certificate | Replace `nats-server-tls` (or let cert-manager renew it); the reloader applies it. |
| NATS / PostgreSQL CA | Publish a bundle with old and new CA in every CA Secret and on workers, switch the server certificate, then drop the old CA. |

With a chart-created Secret, change `server.secret.*` and `helm upgrade`: the
pod checksum annotation restarts crono-server. For a pre-created Secret,
update one key without retyping the others:

```sh
kubectl -n crono create secret generic crono-server --dry-run=client -o yaml \
  --from-file=CRONO_AUTH_DEVELOPMENT_TOKEN=dev-token \
  --from-file=PGPASSWORD=crono_runtime.password \
  --from-file=nats.nkey=crono-server.nk | kubectl apply -f -
```

**Runtime database password:** `00_init.sql` does not change an existing
role's password, so rotate it directly:

```sh
umask 077
openssl rand -hex 32 | tr -d '\n' > crono_runtime.password
echo "ALTER ROLE crono_runtime PASSWORD :'pw';" \
  | psql "$ADMIN_URL" -v ON_ERROR_STOP=1 -v pw="$(cat crono_runtime.password)"
kubectl -n crono patch secret crono-server --type merge \
  -p "{\"data\":{\"PGPASSWORD\":\"$(base64 -w0 < crono_runtime.password)\"}}"
kubectl -n crono rollout restart deploy/crono-server
shred -u crono_runtime.password
```

Existing connections keep working until recycled, so the rollout is seamless.

## Known issues

- **crono-web images up to 0.1.8 crash as uid 101**: they ship
  `/etc/nginx/snippets` with mode `0444`, so unprivileged nginx fails with
  `open() "/etc/nginx/snippets/security-headers.conf" failed (13: Permission
  denied)` and the pods crash-loop. Fixed in crono 0.1.9 (the chart default);
  do not pin crono-web below 0.1.9. The kind smoke test skips crono-web while
  it pins 0.1.8 (`CRONO_SMOKE_WEB`).
- **NATS before crono 0.1.9**: crono-server images up to 0.1.8 support neither
  NATS TLS/NKey authentication nor PostgreSQL TLS; use them only against
  plaintext evaluation setups.

## Disaster recovery

| Failure | Impact | Recovery |
|---|---|---|
| One crono pod or node | none (2 replicas, PDB) | automatic |
| crono namespace deleted | API down, no data loss (stateless) | recreate Secrets, reinstall the release |
| One NATS server | none for the RF3 stream | automatic; node-bound volumes: [node and volume loss](#backup-and-restore) |
| Two NATS servers | stream unavailable, dispatch paused (outbox keeps everything) | restore nodes/volumes or the stream backup |
| All NATS data | dispatch paused until the stream exists | restore the backup or start empty; restart workers |
| PostgreSQL | crono not ready, no new work | restore PostgreSQL; crono resumes from the restored state |
| Whole cluster | everything in-cluster | new cluster, Secrets from your vault, NATS + crono releases, restore the stream backup or start empty |

**PostgreSQL restore = new truth.** Dispatches still in NATS for Attempts the
restored database no longer considers claimable are refused at claim time;
unpublished outbox rows are published again. Procedure:
`kubectl -n crono scale deploy/crono-server --replicas=0`, restore, run
`check.sql`, `helm -n crono upgrade crono ... --reuse-values` (or scale back
up), then watch `/health` and `GET /api/monitor`. For failover, point
`server.database.host` at the new primary or use a stable DNS name.

Keep off-cluster: NATS stream backups, the NATS CA key, the development token
and PostgreSQL backups.

## Chart releases

`crono-server`, `crono-web` and `crono-stack` are versioned in lockstep
(`scripts/ci/check-chart-versions.sh`).

1. Bump `version` in the three `Chart.yaml` files and the two `crono-stack`
   dependency entries; bump `appVersion` in all three when the default crono
   release changes (its images must be published first).
2. `helm repo add nats https://nats-io.github.io/k8s/helm/charts/ --force-update`,
   `helm dependency update charts/crono-stack` (refreshes the committed
   `Chart.lock`) and
   `helm-docs --chart-search-root charts --template-files README.md.gotmpl`.
3. `scripts/ci/validate.sh` (and `scripts/ci/kind-smoke.sh`); open a pull
   request. CI runs both plus `ct lint` with the version-increment check.
4. After merging, publish a GitHub Release tagged `X.Y.Z`.
   `publish-charts.yml` (also runnable manually with a version) verifies that
   every chart is at that version and validates, then checks all three charts
   through the GitHub Packages API before pushing any (a missing package or a
   package without the `X.Y.Z` tag is absent): absent charts are pushed to
   `oci://ghcr.io/crono-io/charts`, existing versions are never overwritten,
   and any other API failure aborts the run. Each pushed digest is signed with
   cosign (keyless, GitHub OIDC) and listed in the job summary. An existing
   version must already verify against this workflow's identity; otherwise
   the run aborts before pushing anything and never signs it, since its
   content may not match the release commit. Inspect that package version,
   delete it manually in GHCR (package settings), then re-run. Re-running for
   the same version resumes a partial publish: missing charts are pushed and
   signed; when all three exist and verify, the run succeeds without changes.
5. Verify: `cosign verify ghcr.io/crono-io/charts/crono-stack:X.Y.Z
   --certificate-identity-regexp '^https://github\.com/crono-io/crono-helm/\.github/workflows/publish-charts\.yml@refs/'
   --certificate-oidc-issuer https://token.actions.githubusercontent.com`.
