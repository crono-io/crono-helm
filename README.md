# crono-helm

Helm charts for [crono](https://github.com/crono-io/crono), a distributed job
scheduler: the stateless control plane (`crono-server`), the web app
(`crono-web`) and an umbrella chart (`crono-stack`) that installs both and can
bundle a single-node NATS JetStream for evaluation. Charts are published to
`oci://ghcr.io/crono-io/charts` and signed with cosign.

PostgreSQL and the execution workers (`crono-worker`) always run outside these
charts. GitOps tooling, cluster provisioning and environment-specific values
belong in your own deployment repository.

```
            Ingress (one host)
            /api ─────────► crono-server x2 ──► PostgreSQL (external, TLS)
            /    ─────────► crono-web x2            │
                                                    ▼
                         NATS JetStream (bundled single node, or your own
                         3-node cluster with TLS + NKeys) ◄── crono-worker hosts
```

## Choose your path

### Evaluation: crono-stack with bundled NATS

You bring a PostgreSQL database with the crono schema applied
([install guide](docs/install-guide.md#database-schema)); the chart creates the
credentials Secret and runs one NATS JetStream server without TLS or
authentication inside the release:

```sh
helm install crono oci://ghcr.io/crono-io/charts/crono-stack --version 0.2.0 \
  --namespace crono --create-namespace \
  --set nats.enabled=true \
  --set server.nats.url=nats://crono-nats.crono.svc.cluster.local:4222 \
  --set server.database.host=postgres.example.internal \
  --set server.secret.authToken="$(openssl rand -hex 32)" \
  --set server.secret.databasePassword='<crono_runtime password>' \
  --wait
```

The namespace must allow the `baseline` Pod Security level (the upstream NATS
image runs as root). Not for production: one NATS server, no TLS, no
authentication, so external workers cannot connect safely.

### Production: external PostgreSQL, managed NATS cluster, external workers

- PostgreSQL with TLS (`sslmode=verify-full`) and the schema applied by an
  operator before every image upgrade;
- a separately managed 3-server NATS JetStream cluster with TLS and one NKey
  user per client, so the `CRONO_DISPATCH` stream is replicated three times
  (RF3): [docs/examples/nats-jetstream-ha.yaml](docs/examples/nats-jetstream-ha.yaml)
  for the official NATS chart;
- crono-stack with pre-created Secrets, digest-pinned images, Ingress and
  NetworkPolicies: [docs/examples/production-stack.yaml](docs/examples/production-stack.yaml);
- workers on their own hosts, connecting to NATS over TLS with per-worker
  permissions ([operations](docs/operations.md#external-workers)).

Follow the [installation guide](docs/install-guide.md) step by step.

> **Image availability.** The charts default to crono **0.1.9** (`appVersion`),
> the first release with NATS TLS/NKey support and PostgreSQL TLS. Its images
> (`ghcr.io/crono-io/crono-server:0.1.9`, `crono-web:0.1.9`) must be published
> before a default install can pull them; until then pin `image.tag`/`digest`
> to a published release, which supports only plaintext NATS without
> authentication and `sslMode: disable` (evaluation only).

## Requirements and chart references

| | Supported |
|---|---|
| Kubernetes | 1.30+ (native `preStop.sleep`); CI smoke-tests 1.37 on kind |
| Helm | 3.8+ (OCI registries); CI uses 3.22 |
| PostgreSQL | 16+ (CI fixture: 18), schema from crono `db/sql` of the same release |
| NATS | 2.10+ with JetStream; bundled and documented: chart/server 2.15.2 |
| crono | chart 0.2.x deploys crono 0.1.9 by default |

| Chart | Purpose | Values reference |
|---|---|---|
| `crono-stack` | umbrella: `server`, `web`, optional `nats` | [charts/crono-stack](charts/crono-stack/README.md) |
| `crono-server` | API, scheduler, dispatcher, worker-control responders | [charts/crono-server](charts/crono-server/README.md) |
| `crono-web` | single-page app (nginx) | [charts/crono-web](charts/crono-web/README.md) |

Install a component on its own with
`helm install <name> oci://ghcr.io/crono-io/charts/crono-server --version 0.2.0 ...`.

Further reading: [installation guide](docs/install-guide.md) (prerequisites,
schema, Secrets, NATS options, install, verify, upgrade, rollback, uninstall)
and [operations](docs/operations.md) (workers, NATS HA and backups, network
policy, availability, disaster recovery, releases).

## Verify a chart signature

Every published chart digest is signed keylessly by the release workflow:

```sh
cosign verify ghcr.io/crono-io/charts/crono-stack:0.2.0 \
  --certificate-identity-regexp '^https://github\.com/crono-io/crono-helm/\.github/workflows/publish-charts\.yml@refs/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## Validation and release

```sh
scripts/ci/install-tools.sh .tools        # pinned, checksum-verified (linux/amd64)
TOOLS_DIR=$PWD/.tools scripts/ci/validate.sh
TOOLS_DIR=$PWD/.tools scripts/ci/kind-smoke.sh   # needs Docker or KIND_EXPERIMENTAL_PROVIDER=podman
```

`validate.sh` checks version alignment, lints, unit-tests (helm-unittest) and
kubeconform-validates every chart, proves invalid values are refused, renders
both examples, checks that chart READMEs match helm-docs, runs `ct lint` (when
installed), actionlint, the release-event fixtures and a secret scan.
`kind-smoke.sh` installs crono-stack with bundled NATS against a throwaway
PostgreSQL fixture and checks `/ready`, `/health`, the API and Pod Security.
CI (`.github/workflows/charts-ci.yml`) runs both.

Releasing is automated: a promoted crono release sends a `crono-release`
dispatch, `.github/workflows/release-bump-pr.yml` opens a
`release/crono-X.Y.Z` pull request (appVersion, next chart version, image
digests, `Chart.lock`, READMEs and the kind smoke pin, via
`scripts/ci/bump-release.sh`), and after it merges and Charts CI passes on
`main`, `.github/workflows/auto-release.yml` creates the GitHub release for the
chart version and dispatches `.github/workflows/publish-charts.yml`. That
workflow refuses mismatched versions, checks all three charts in the registry
first (never overwriting an existing version, aborting on registry errors),
pushes the missing ones to GHCR and signs each digest; re-running it resumes a
partial publish. Chart-only changes are bumped by hand. Details:
[operations](docs/operations.md#chart-releases).

Never commit secret material: NKey seeds, tokens, passwords and private keys
live in Kubernetes Secrets created out of band.
