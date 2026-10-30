#!/usr/bin/env bash
# Local runner for the static checks CI performs (no cluster needed):
#   1. chart versions and umbrella dependencies are aligned;
#   2. crono-stack dependencies build from Chart.lock (pinned NATS chart);
#   3. every chart: helm lint --strict and kubeconform with each ci/*.yaml, and
#      helm-unittest;
#   4. negative renders through the umbrella (missing required values, image
#      digest enforcement, bad digest);
#   5. docs/examples render: production-stack.yaml through crono-stack, and
#      nats-jetstream-ha.yaml through the pinned NATS chart (3 replicas, 20Gi
#      PVC, TLS, anti-affinity, optional LoadBalancer); the bundled evaluation
#      NATS renders one JetStream server;
#   6. chart READMEs match helm-docs output;
#   7. ct lint when ct, yamllint and yamale are available (CI always runs it);
#   8. actionlint on every workflow;
#   9. no NKey seeds or private keys anywhere in the tree.
#
# Requires network access (NATS chart repository, kubeconform schemas) and
# helm (+ helm-unittest plugin), kubeconform, helm-docs and actionlint on PATH
# or in TOOLS_DIR (scripts/ci/install-tools.sh installs the pinned versions).
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$root"
if [[ -n "${TOOLS_DIR:-}" ]]; then
  PATH="$TOOLS_DIR:$PATH"
fi
for tool in helm kubeconform helm-docs actionlint; do
  command -v "$tool" >/dev/null || {
    echo "missing $tool (set TOOLS_DIR or run scripts/ci/install-tools.sh)" >&2
    exit 1
  }
done
helm plugin list | grep -q '^unittest' || {
  echo "missing the helm-unittest plugin (scripts/ci/install-tools.sh installs it)" >&2
  exit 1
}

kubeconform_args=(-strict -summary)
if [[ -n "${KUBERNETES_VERSION:-}" ]]; then
  kubeconform_args+=(-kubernetes-version "$KUBERNETES_VERSION")
fi
charts=(charts/crono-server charts/crono-web charts/crono-stack)
stack=charts/crono-stack
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

step() { printf '\n==> %s\n' "$*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
# require FILE PATTERN DESCRIPTION: fixed-string match in rendered output.
require() { grep -qF -- "$2" "$1" || fail "$3 (expected '$2' in $1)"; }
# must_fail DESCRIPTION PATTERN HELM_TEMPLATE_ARGS...: rendering must fail and
# the error must match the extended regex PATTERN.
must_fail() {
  local description=$1 pattern=$2
  shift 2
  if helm template crono "$stack" --namespace crono "$@" >/dev/null 2>"$work/err"; then
    fail "rendered although $description"
  fi
  grep -qE -- "$pattern" "$work/err" || { cat "$work/err" >&2; fail "$description: error does not match /$pattern/"; }
  echo "ok: refused ($description)"
}

step "chart versions"
scripts/ci/check-chart-versions.sh

step "helm dependency build $stack"
# Fresh Helm configs (CI runners) have no repositories; Chart.lock needs one.
helm repo add nats https://nats-io.github.io/k8s/helm/charts/ --force-update >/dev/null
helm dependency build "$stack" >/dev/null
nats_chart=$(ls "$stack"/charts/nats-*.tgz)
nats_version=${nats_chart##*/nats-}
nats_version=${nats_version%.tgz}
echo "ok: crono-server, crono-web, nats $nats_version vendored"

for chart in "${charts[@]}"; do
  shopt -s nullglob
  ci_values=("$chart"/ci/*.yaml)
  shopt -u nullglob
  [[ ${#ci_values[@]} -gt 0 ]] || fail "$chart has no ci/*.yaml"
  for values in "${ci_values[@]}"; do
    step "lint + kubeconform $chart with $values"
    helm lint --strict "$chart" -f "$values"
    helm template crono "$chart" --namespace crono -f "$values" | kubeconform "${kubeconform_args[@]}"
  done
  step "helm unittest $chart"
  helm unittest "$chart"
done

step "negative renders through the umbrella"
required=(--set server.database.host=db --set server.nats.url=nats://nats:4222
  --set server.secret.authToken=0123456789abcdef0123456789abcdef --set server.secret.databasePassword=pw)
must_fail "server.nats.url is missing" 'nats[/:. ]+url' \
  --set server.database.host=db --set server.secret.authToken=0123456789abcdef0123456789abcdef \
  --set server.secret.databasePassword=pw
must_fail "server.database.host is missing" 'database[/.]host' \
  --set server.nats.url=nats://nats:4222 --set server.secret.authToken=0123456789abcdef0123456789abcdef \
  --set server.secret.databasePassword=pw
must_fail "no Secret and no authToken" 'secret.authToken is required' \
  --set server.database.host=db --set server.nats.url=nats://nats:4222 --set server.secret.databasePassword=pw
must_fail "requireImageDigest without a server digest" 'image.digest is required when requireImageDigest is true' \
  "${required[@]}" --set server.requireImageDigest=true
must_fail "requireImageDigest without a web digest" 'image.digest is required when requireImageDigest is true' \
  "${required[@]}" --set web.requireImageDigest=true
must_fail "a non-sha256 digest" 'image[/.]digest' "${required[@]}" --set server.image.digest=latest
must_fail "an unknown umbrella key" 'additional properties|additionalProperties|not allowed' \
  "${required[@]}" --set postgres.enabled=true

step "docs/examples/production-stack.yaml through crono-stack"
rendered="$work/production.yaml"
helm template crono "$stack" --namespace crono -f docs/examples/production-stack.yaml >"$rendered"
kubeconform "${kubeconform_args[@]}" "$rendered"
require "$rendered" 'image: "ghcr.io/crono-io/crono-server@sha256:' "server image not pinned by digest"
require "$rendered" 'image: "ghcr.io/crono-io/crono-web@sha256:' "web image not pinned by digest"
require "$rendered" "kind: NetworkPolicy" "no NetworkPolicy rendered"
require "$rendered" "sslmode=verify-full" "PostgreSQL TLS is not verify-full"
require "$rendered" "tls://nats.nats.svc.cluster.local:4222" "NATS URL is not TLS"
if grep -q "kind: StatefulSet" "$rendered"; then fail "production profile must not bundle NATS"; fi
echo "ok: digests, NetworkPolicies, verify-full, TLS NATS, no bundled NATS"

step "docs/examples/nats-jetstream-ha.yaml through nats $nats_version"
for service_type in ClusterIP LoadBalancer; do
  rendered="$work/nats-$service_type.yaml"
  helm template nats "$nats_chart" --namespace nats -f docs/examples/nats-jetstream-ha.yaml \
    --set service.merge.spec.type="$service_type" >"$rendered"
  kubeconform "${kubeconform_args[@]}" "$rendered"
  require "$rendered" "kind: StatefulSet" "no StatefulSet rendered"
  require "$rendered" "  replicas: 3" "NATS is not 3 replicas"
  require "$rendered" "storage: 20Gi" "JetStream PVC is not 20Gi"
  require "$rendered" '"cert_file": "/etc/nats-certs/nats/tls.crt"' "client TLS missing"
  require "$rendered" '"cert_file": "/etc/nats-certs/cluster/tls.crt"' "route TLS missing"
  require "$rendered" '"ca_file": "/etc/nats-ca-cert/ca.crt"' "TLS CA missing"
  require "$rendered" '"system_account": "SYS"' "system account missing"
  require "$rendered" "requiredDuringSchedulingIgnoredDuringExecution" "hostname anti-affinity missing"
  require "$rendered" "type: $service_type" "Service type $service_type not applied"
  if grep -q "nats-box" "$rendered"; then fail "nats-box must be disabled"; fi
done
echo "ok: 3 replicas, 20Gi PVC, TLS, anti-affinity, ClusterIP or LoadBalancer"

step "bundled evaluation NATS (crono-stack ci values)"
rendered="$work/stack-nats.yaml"
helm template crono "$stack" --namespace crono -f "$stack/ci/ct-values.yaml" >"$rendered"
require "$rendered" "name: crono-nats" "bundled NATS not named <release>-nats"
require "$rendered" "  replicas: 1" "bundled NATS is not a single server"
require "$rendered" '"max_file_store": 10Gi' "bundled NATS has no JetStream file store"
echo "ok: one JetStream server"

step "chart READMEs match helm-docs"
cp -R charts "$work/charts"
helm-docs --log-level warning --chart-search-root "$work/charts" --template-files README.md.gotmpl
for chart in "${charts[@]}"; do
  diff -u "$chart/README.md" "$work/$chart/README.md" \
    || fail "$chart/README.md is stale; run: helm-docs --chart-search-root charts --template-files README.md.gotmpl"
done
echo "ok: READMEs up to date"

step "ct lint"
if command -v ct >/dev/null && command -v yamllint >/dev/null && command -v yamale >/dev/null; then
  if [[ -z "${CT_CONFIG_DIR:-}" && -d "$(dirname "$(command -v ct)")/ct-etc" ]]; then
    export CT_CONFIG_DIR
    CT_CONFIG_DIR="$(dirname "$(command -v ct)")/ct-etc"
  fi
  # The version-increment check compares against the PR target branch; CI runs it.
  ct lint --all --config .ct.yaml --check-version-increment=false
else
  echo "skipped: needs ct, yamllint and yamale on PATH (CI runs ct lint)"
fi

step "actionlint"
actionlint .github/workflows/*.yml
echo "ok: workflows"

step "no secret material in the tree"
# NKey seeds (S + key type + base32) and PEM private keys must never be committed.
# grep exits 0 on a match, 1 on none and 2 on errors; only 1 is a pass.
status=0
grep -rIlE --exclude-dir=.git --exclude-dir=.tools \
  -e 'S[UNAOC][A-Z2-7]{56}' -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' . || status=$?
case $status in
  1) echo "ok: no seeds or private keys" ;;
  0) fail "possible NKey seed or private key in the files listed above" ;;
  *) fail "secret scan could not run (grep exit $status)" ;;
esac
printf '\nall checks passed\n'
