#!/usr/bin/env bash
# End-to-end smoke test of charts/crono-stack on a throwaway kind cluster:
#   1. create (or reuse) a kind cluster;
#   2. deploy PostgreSQL 18 as a CI-only fixture (no TLS, ephemeral storage) and
#      apply the crono schema (db/sql/00_init.sql + check.sql) from crono-io/crono
#      at a pinned commit;
#   3. install crono-stack with the bundled single-node NATS JetStream and a
#      chart-created Secret, images pinned by digest (requireImageDigest: true);
#   4. assert /ready is 200, /health reports database and NATS "available", an
#      authenticated API call succeeds, crono-web serves the app and refuses
#      /api, and the crono pods would also pass the `restricted` Pod Security
#      level (the namespace enforces `baseline` because upstream NATS runs as root);
#   5. dump cluster state and logs on failure; delete the cluster it created.
#
# Requires kind, kubectl, helm, git, curl, openssl and a container runtime
# (Docker, or KIND_EXPERIMENTAL_PROVIDER=podman). Tools: scripts/ci/install-tools.sh.
#
# Environment:
#   KIND_CLUSTER_NAME   cluster name (default crono-smoke). An existing cluster
#                       with that name is reused and kept.
#   KIND_NODE_IMAGE     node image (default pinned below).
#   KEEP_CLUSTER=1      keep a cluster this script created.
#   CRONO_SQL_DIR       use a local db/sql directory instead of fetching it.
#   CRONO_SMOKE_*       application under test; override the version, commit
#                       and both digests together.
#   CRONO_SMOKE_WEB     `check` deploys and probes crono-web; `skip` installs
#                       with web.enabled=false. Defaults to `check` from crono
#                       0.1.9 and to `skip` before: crono-web images up to
#                       0.1.8 ship /etc/nginx/snippets as mode 0444, so nginx
#                       cannot start as its unprivileged user (fixed in 0.1.9).
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$root"
if [[ -n "${TOOLS_DIR:-}" ]]; then
  PATH="$TOOLS_DIR:$PATH"
fi

cluster=${KIND_CLUSTER_NAME:-crono-smoke}
node_image=${KIND_NODE_IMAGE:-kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5}
# Application under test. The chart defaults to crono 0.1.9 (appVersion); the
# smoke test pins the newest published images and the schema of the same
# release. 0.1.8 has no NATS TLS/auth support, which the bundled evaluation
# NATS (plain, unauthenticated) does not need.
crono_version=${CRONO_SMOKE_VERSION:-0.1.8}
crono_commit=${CRONO_SMOKE_COMMIT:-1392949bc26f00a1ba57813fd0aa09cebb33cfb1} # tag 0.1.8 (peeled)
server_digest=${CRONO_SMOKE_SERVER_DIGEST:-sha256:fcfdda540b4ac788621d36ba1c868a8a17d79ed46e477b332a34ab8e014d25ec}
web_digest=${CRONO_SMOKE_WEB_DIGEST:-sha256:6ebfb1fbcdb29e1af65163cf33c53af12edc2e3a995f1f49d779442ac213d18e}
# crono-web images before 0.1.9 cannot start unprivileged (see above).
if [[ $(printf '%s\n' "$crono_version" 0.1.9 | sort -V | head -n 1) == 0.1.9 ]]; then
  web_mode=${CRONO_SMOKE_WEB:-check}
else
  web_mode=${CRONO_SMOKE_WEB:-skip}
fi
[[ $web_mode == check || $web_mode == skip ]] || { echo "CRONO_SMOKE_WEB must be check or skip" >&2; exit 2; }
postgres_image=postgres:18.6@sha256:979bccfde35445db618c65107d27d08c6c21339d8dc3ad4c830c6633947be0e4

context="kind-$cluster"
db_ns=crono-smoke-db
ns=crono-smoke
release=crono

for tool in kind kubectl helm git curl openssl; do
  command -v "$tool" >/dev/null || { echo "missing $tool" >&2; exit 1; }
done

work=$(mktemp -d)
created_cluster=false
pf_pids=()

k() { kubectl --context "$context" "$@"; }
step() { printf '\n==> %s\n' "$*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

dump_state() {
  echo "::group::cluster state and logs" 2>/dev/null || true
  for n in "$ns" "$db_ns"; do
    k -n "$n" get all,pvc,secrets,configmaps -o wide || true
    k -n "$n" get events --sort-by=.lastTimestamp || true
    k -n "$n" describe pods || true
    for pod in $(k -n "$n" get pods -o name 2>/dev/null); do
      echo "--- logs $n/$pod"
      k -n "$n" logs "$pod" --all-containers --prefix --tail=200 || true
      k -n "$n" logs "$pod" --all-containers --prefix --tail=50 --previous 2>/dev/null || true
    done
  done
  helm --kube-context "$context" -n "$ns" status "$release" || true
  echo "::endgroup::" 2>/dev/null || true
}

cleanup() {
  local status=$?
  for pid in "${pf_pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  if [[ $status -ne 0 ]]; then
    echo "smoke test failed (exit $status); collecting diagnostics" >&2
    dump_state
  fi
  if [[ $created_cluster == true && "${KEEP_CLUSTER:-0}" != 1 ]]; then
    kind delete cluster --name "$cluster" || true
  fi
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT

# port_forward SVC LOCAL REMOTE: background port-forward, waits until it answers.
port_forward() {
  k -n "$ns" port-forward "svc/$1" "$2:$3" >"$work/pf-$1.log" 2>&1 &
  pf_pids+=($!)
  for _ in $(seq 1 30); do
    if curl -s -o /dev/null "http://127.0.0.1:$2/"; then return 0; fi
    sleep 1
  done
  cat "$work/pf-$1.log" >&2
  fail "port-forward to svc/$1 did not come up"
}

step "kind cluster $cluster"
if kind get clusters 2>/dev/null | grep -qx "$cluster"; then
  echo "reusing existing cluster $cluster"
else
  kind create cluster --name "$cluster" --image "$node_image" --wait 180s
  created_cluster=true
fi
k version
k wait --for=condition=Ready nodes --all --timeout=180s

step "crono schema at $crono_commit"
if [[ -n "${CRONO_SQL_DIR:-}" ]]; then
  sql_dir=$CRONO_SQL_DIR
else
  git init -q "$work/crono"
  git -C "$work/crono" fetch -q --depth 1 https://github.com/crono-io/crono.git "$crono_commit"
  git -C "$work/crono" checkout -q FETCH_HEAD
  [[ $(git -C "$work/crono" rev-parse HEAD) == "$crono_commit" ]] || fail "fetched commit mismatch"
  sql_dir="$work/crono/db/sql"
fi
for f in 00_init.sql 01_crono.sql 02_workflows.sql check.sql; do
  [[ -f "$sql_dir/$f" ]] || fail "missing $sql_dir/$f"
done

step "PostgreSQL fixture ($postgres_image)"
umask 077
openssl rand -hex 24 >"$work/postgres.password"
openssl rand -hex 24 >"$work/runtime.password"
openssl rand -hex 32 >"$work/token"
k create namespace "$db_ns"
k -n "$db_ns" create secret generic postgres --from-file=POSTGRES_PASSWORD="$work/postgres.password"
k -n "$db_ns" apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
spec:
  replicas: 1
  selector:
    matchLabels: {app: postgres}
  template:
    metadata:
      labels: {app: postgres}
    spec:
      containers:
        - name: postgres
          image: $postgres_image
          envFrom:
            - secretRef: {name: postgres}
          ports:
            - containerPort: 5432
          readinessProbe:
            exec:
              command: ["pg_isready", "-U", "postgres", "-h", "127.0.0.1"]
            periodSeconds: 2
          volumeMounts:
            - {name: data, mountPath: /var/lib/postgresql}
      volumes:
        - name: data
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
spec:
  selector: {app: postgres}
  ports:
    - port: 5432
      targetPort: 5432
EOF
k -n "$db_ns" rollout status deploy/postgres --timeout=300s

step "apply 00_init.sql and check.sql"
k -n "$db_ns" exec deploy/postgres -- mkdir -p /tmp/crono-sql
tar -C "$sql_dir" -cf - . | k -n "$db_ns" exec -i deploy/postgres -- tar -xf - -C /tmp/crono-sql
# The runtime password goes through stdin (psql variables cannot be set from
# stdin, so a one-line preamble sets it before including the bootstrap file).
{
  printf '\\set crono_runtime_password %s\n' "$(cat "$work/runtime.password")"
  printf '\\cd /tmp/crono-sql\n\\i 00_init.sql\n'
} | k -n "$db_ns" exec -i deploy/postgres -- psql -U postgres -d postgres -v ON_ERROR_STOP=1 -q
k -n "$db_ns" exec deploy/postgres -- psql -U postgres -d postgres -v ON_ERROR_STOP=1 -f /tmp/crono-sql/check.sql

step "install crono-stack (bundled NATS, crono $crono_version)"
k create namespace "$ns"
# Upstream NATS runs as root: enforce baseline, warn on restricted.
k label namespace "$ns" pod-security.kubernetes.io/enforce=baseline pod-security.kubernetes.io/warn=restricted
helm repo add nats https://nats-io.github.io/k8s/helm/charts/ --force-update
helm dependency build charts/crono-stack
cat >"$work/values.yaml" <<EOF
server:
  requireImageDigest: true
  image:
    tag: "$crono_version"
    digest: "$server_digest"
  database:
    host: postgres.$db_ns.svc.cluster.local
    sslMode: disable
  nats:
    url: nats://$release-nats.$ns.svc.cluster.local:4222
    replicas: 1
  secret:
    authToken: "$(cat "$work/token")"
    databasePassword: "$(cat "$work/runtime.password")"
  logLevel: info
web:
  enabled: $([[ $web_mode == check ]] && echo true || echo false)
  requireImageDigest: true
  image:
    tag: "$crono_version"
    digest: "$web_digest"
nats:
  enabled: true
  # Default 10Gi file store: crono's CRONO_DISPATCH stream reserves 8 GiB
  # (max_bytes), so a smaller JetStream store refuses to create it.
EOF
helm --kube-context "$context" install "$release" charts/crono-stack --namespace "$ns" \
  -f "$work/values.yaml" --wait --timeout 10m
k -n "$ns" rollout status deploy/"$release"-server --timeout=300s
if [[ $web_mode == check ]]; then
  k -n "$ns" rollout status deploy/"$release"-web --timeout=300s
else
  echo "WARNING: crono-web not deployed (CRONO_SMOKE_WEB=skip, see the header of this script)"
fi
k -n "$ns" rollout status statefulset/"$release"-nats --timeout=300s

step "running images are the pinned digests"
# image_of DEPLOYMENT: image of its first container.
image_of() { k -n "$ns" get deploy "$1" -o jsonpath='{.spec.template.spec.containers[0].image}'; }
image=$(image_of "$release-server")
[[ $image == "ghcr.io/crono-io/crono-server@$server_digest" ]] || fail "server image: $image"
echo "ok: $image"
if [[ $web_mode == check ]]; then
  image=$(image_of "$release-web")
  [[ $image == "ghcr.io/crono-io/crono-web@$web_digest" ]] || fail "web image: $image"
  echo "ok: $image"
fi

step "crono-server endpoints"
port_forward "$release-server" 18080 8080
code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18080/ready)
[[ $code == 200 ]] || fail "/ready returned $code"
echo "ok: /ready 200"
health=""
for _ in $(seq 1 30); do
  health=$(curl -fsS http://127.0.0.1:18080/health) || health=""
  if grep -q '"database":"available"' <<<"$health" && grep -q '"nats":"available"' <<<"$health"; then
    break
  fi
  sleep 2
done
grep -q '"database":"available"' <<<"$health" || fail "/health database: $health"
grep -q '"nats":"available"' <<<"$health" || fail "/health nats: $health"
echo "ok: /health $health"
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(cat "$work/token")" http://127.0.0.1:18080/api/queues)
[[ $code == 200 ]] || fail "authenticated GET /api/queues returned $code"
code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18080/api/queues)
[[ $code == 401 ]] || fail "unauthenticated GET /api/queues returned $code, expected 401"
echo "ok: /api/queues 200 with the token, 401 without"

if [[ $web_mode == check ]]; then
  step "crono-web"
  port_forward "$release-web" 18081 8080
  code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18081/)
  [[ $code == 200 ]] || fail "web / returned $code"
  code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:18081/api/queues)
  [[ $code == 404 ]] || fail "web /api/queues returned $code, expected 404"
  echo "ok: web serves / and refuses /api"
fi

step "crono pods satisfy the restricted Pod Security level"
k label namespace "$ns" pod-security.kubernetes.io/enforce=restricted --overwrite --dry-run=server \
  >"$work/psa.out" 2>&1 || { cat "$work/psa.out" >&2; fail "restricted dry-run failed"; }
cat "$work/psa.out"
if grep -E "$release-(server|web)-" "$work/psa.out"; then
  fail "crono pods violate the restricted Pod Security level"
fi
echo "ok: only upstream NATS pods (if any) are reported"

printf '\nkind smoke test passed\n'
