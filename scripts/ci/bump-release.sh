#!/usr/bin/env bash
# Point the charts at a crono release:
#   - appVersion of crono-server, crono-web and crono-stack = VERSION;
#   - chart version of all three (and the two crono-stack dependency entries)
#     = --chart-version, or the next patch of the current chart version;
#   - image.digest of crono-server and crono-web (their values.yaml and the
#     server/web blocks of crono-stack/values.yaml) = the release's promoted
#     image index digests; image.tag stays "" (= appVersion);
#   - the kind smoke test (scripts/ci/kind-smoke.sh) pins the same release:
#     version, source commit (db/sql schema) and both digests;
#   - `--version <chart>` and `charts/crono-*:<chart>` references in README.md,
#     docs/*.md and docs/examples/*.yaml follow the chart version;
#   - crono-stack/Chart.lock and the chart READMEs (helm-docs) are regenerated;
#   - the source commit is recorded as the `crono/source-commit` annotation of
#     crono-stack/Chart.yaml.
#
# Usage:
#   scripts/ci/bump-release.sh --version X.Y.Z --source-sha <40 hex> \
#     --server-digest sha256:<64 hex> --web-digest sha256:<64 hex> \
#     [--chart-version X.Y.Z]
#
# Replays are no-ops: without --chart-version, when appVersion, the recorded
# source commit and every recorded digest already match, the script changes
# nothing and exits 0. Otherwise the chart version must be greater than the
# current one, and VERSION may not be older than the current appVersion. Every
# input is validated and every text edit is staged before the tree changes;
# Chart.lock and the READMEs are regenerated last. Needs helm and helm-docs on
# PATH or in TOOLS_DIR, and network access (NATS chart repository). Used by
# release-bump-pr.yml.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$root"
if [[ -n "${TOOLS_DIR:-}" ]]; then
  PATH="$TOOLS_DIR:$PATH"
fi

semver='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
sha_re='^[0-9a-f]{40}$'
digest_re='^sha256:[0-9a-f]{64}$'

usage() { sed -n '17,20p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die() { echo "bump-release: $*" >&2; exit 1; }
# newer A B: A is a strictly greater X.Y.Z than B.
newer() { [[ $1 != "$2" && $(printf '%s\n' "$1" "$2" | sort -V | tail -n 1) == "$1" ]]; }

version="" chart_version="" source_sha="" server_digest="" web_digest=""
while [[ $# -gt 0 ]]; do
  [[ $# -ge 2 ]] || usage
  case $1 in
    --version) version=${2#v} ;;
    --chart-version) chart_version=${2#v} ;;
    --source-sha) source_sha=$2 ;;
    --server-digest) server_digest=$2 ;;
    --web-digest) web_digest=$2 ;;
    *) usage ;;
  esac
  shift 2
done
[[ $version =~ $semver ]] || die "--version must be X.Y.Z or vX.Y.Z"
[[ -z $chart_version || $chart_version =~ $semver ]] || die "--chart-version must be X.Y.Z or vX.Y.Z"
[[ $source_sha =~ $sha_re ]] || die "--source-sha must be a 40-hex commit SHA"
[[ $server_digest =~ $digest_re ]] || die "--server-digest must be sha256:<64 lowercase hex>"
[[ $web_digest =~ $digest_re ]] || die "--web-digest must be sha256:<64 lowercase hex>"
for tool in helm helm-docs; do
  command -v "$tool" >/dev/null || die "missing $tool (set TOOLS_DIR or run scripts/ci/install-tools.sh)"
done

scripts/ci/check-chart-versions.sh >/dev/null
stack_chart=charts/crono-stack/Chart.yaml
stack_values=charts/crono-stack/values.yaml
current=$(awk '/^version:/ { print $2; exit }' "$stack_chart")
current_app=$(awk '/^appVersion:/ { gsub(/"/, "", $2); print $2; exit }' "$stack_chart")

# Recorded release state: source commit annotation and image digests.
recorded_sha=$(awk '/^annotations:/ { a = 1; next } a && /^[^[:space:]#]/ { a = 0 }
  a && /^  crono\/source-commit:/ { v = $2; gsub(/"/, "", v); print v; exit }' "$stack_chart")
# component_digest FILE: image.digest of the top-level `image:` block.
component_digest() {
  awk '/^image:[[:space:]]*$/ { i = 1; next } i && /^[^[:space:]#]/ { i = 0 }
    i && /^  digest:/ { v = $2; gsub(/"/, "", v); print v; exit }' "$1"
}
# stack_digest SVC: SVC.image.digest in the umbrella values.
stack_digest() {
  awk -v svc="$1" '/^[^[:space:]#]/ { top = $0; sub(/:.*/, "", top); i = 0 }
    top == svc && /^  image:[[:space:]]*$/ { i = 1; next } i && /^  [^[:space:]#]/ { i = 0 }
    i && /^    digest:/ { v = $2; gsub(/"/, "", v); print v; exit }' "$stack_values"
}
if [[ -z $chart_version && $current_app == "$version" && $recorded_sha == "$source_sha" &&
  $(component_digest charts/crono-server/values.yaml) == "$server_digest" &&
  $(component_digest charts/crono-web/values.yaml) == "$web_digest" &&
  $(stack_digest server) == "$server_digest" && $(stack_digest web) == "$web_digest" ]]; then
  echo "charts already at crono $version ($source_sha) with these digests; nothing to do"
  exit 0
fi

if [[ -z $chart_version ]]; then
  chart_version="${current%.*}.$((${current##*.} + 1))"
fi
newer "$chart_version" "$current" || die "chart version $chart_version must be greater than the current $current"
newer "$current_app" "$version" && die "crono $version is older than the current appVersion $current_app"

chart_files=(charts/crono-server/Chart.yaml charts/crono-web/Chart.yaml "$stack_chart")
smoke=scripts/ci/kind-smoke.sh
shopt -s nullglob
docs=(README.md docs/*.md docs/examples/*.yaml)
shopt -u nullglob

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
staged=()
# copy_of FILE: path of FILE's working copy.
copy_of() { printf '%s/%s\n' "$work" "${1//\//__}"; }
# stage FILE: create FILE's working copy once.
stage() {
  [[ -f $(copy_of "$1") ]] && return
  cp -- "$1" "$(copy_of "$1")"
  staged+=("$1")
}
# rewrite FILE AWK_ARGS...: run awk over FILE's working copy in place (the
# program may re-read ARGV[1] in BEGIN).
rewrite() {
  local file=$1 copy
  shift
  stage "$file"
  copy=$(copy_of "$file")
  awk "$@" "$copy" >"$copy.new" || die "$file: unexpected layout"
  mv "$copy.new" "$copy"
}

for file in "${chart_files[@]}"; do
  rewrite "$file" -v v="$chart_version" -v app="$version" '
    /^version:/ { print "version: " v; n++; next }
    /^appVersion:/ { print "appVersion: \"" app "\""; a++; next }
    { print }
    END { if (n != 1 || a != 1) exit 3 }'
done
rewrite "$stack_chart" -v v="$chart_version" '
  /^  - name: crono-(server|web)$/ { dep = 1; print; next }
  dep && /^    version:/ { print "    version: " v; dep = 0; n++; next }
  /^  - name:/ { dep = 0 }
  { print }
  END { if (n != 2) exit 3 }'
# Source commit annotation: replaced, added to an existing `annotations:` map,
# or appended with a new map.
rewrite "$stack_chart" -v sha="$source_sha" '
  BEGIN {
    while ((getline line < ARGV[1]) > 0) {
      if (line ~ /^annotations:/) has_map = 1
      if (line ~ /^  crono\/source-commit:/) has_key = 1
    }
    close(ARGV[1])
  }
  /^[^[:space:]#]/ { in_map = /^annotations:/ }
  in_map && /^  crono\/source-commit:/ { print "  crono/source-commit: \"" sha "\""; n++; next }
  { print }
  /^annotations:/ && !has_key { print "  crono/source-commit: \"" sha "\""; n++ }
  END {
    if (!has_map) {
      print "# crono commit the release was built from (scripts/ci/bump-release.sh)."
      print "annotations:"
      print "  crono/source-commit: \"" sha "\""
      n++
    }
    if (n != 1) exit 3
  }'

# Standalone charts: image.digest of the top-level `image:` block.
for svc in server web; do
  digest_var=${svc}_digest
  rewrite "charts/crono-$svc/values.yaml" -v d="${!digest_var}" '
    /^image:[[:space:]]*$/ { img = 1; print; next }
    img && /^[^[:space:]#]/ { img = 0 }
    img && /^  digest:/ { print "  digest: \"" d "\""; n++; next }
    { print }
    END { if (n != 1) exit 3 }'
done

# Umbrella: server.image.digest and web.image.digest. The first bump adds the
# `image:` block right after the component's `enabled:` line.
rewrite "$stack_values" -v d_server="$server_digest" -v d_web="$web_digest" '
  BEGIN {
    d["server"] = d_server; d["web"] = d_web
    while ((getline line < ARGV[1]) > 0) {
      if (line ~ /^[^[:space:]#]/) { t = line; sub(/:.*/, "", t) }
      if (line ~ /^  image:[[:space:]]*$/) has_image[t] = 1
    }
    close(ARGV[1])
  }
  /^[^[:space:]#]/ { top = $0; sub(/:.*/, "", top); img = 0 }
  !(top in d) { print; next }
  /^  image:[[:space:]]*$/ { img = 1; print; next }
  img && /^  [^[:space:]#]/ { img = 0 }
  img && /^    digest:/ { print "    digest: \"" d[top] "\""; n[top]++; next }
  { print }
  /^  enabled:/ && !(top in has_image) && !(top in added) {
    added[top] = 1
    print "  image:"
    print "    # -- Image index digest of crono-" top " for the chart `appVersion`, set"
    print "    # by each release. It takes precedence over `" top ".image.tag`: set both, or"
    print "    # clear it (`\"\"`) to deploy by tag."
    print "    digest: \"" d[top] "\""
    n[top]++
  }
  END { if (n["server"] != 1 || n["web"] != 1) exit 3 }'

rewrite "$smoke" -v v="$version" -v sha="$source_sha" -v ds="$server_digest" -v dw="$web_digest" '
  /^crono_version=\$\{CRONO_SMOKE_VERSION:-/ { print "crono_version=${CRONO_SMOKE_VERSION:-" v "}"; n++; next }
  /^crono_commit=\$\{CRONO_SMOKE_COMMIT:-/ { print "crono_commit=${CRONO_SMOKE_COMMIT:-" sha "} # crono " v; n++; next }
  /^server_digest=\$\{CRONO_SMOKE_SERVER_DIGEST:-/ { print "server_digest=${CRONO_SMOKE_SERVER_DIGEST:-" ds "}"; n++; next }
  /^web_digest=\$\{CRONO_SMOKE_WEB_DIGEST:-/ { print "web_digest=${CRONO_SMOKE_WEB_DIGEST:-" dw "}"; n++; next }
  { print }
  END { if (n != 4) exit 3 }'

current_re=${current//./\\.}
for file in "${docs[@]}"; do
  grep -qE -- "(--version[[:space:]]+|charts/crono-[a-z]+:)$current_re\\b" "$file" || continue
  stage "$file"
  copy=$(copy_of "$file")
  sed -E -i \
    -e "s#(--version[[:space:]]+)$current_re\\b#\\1$chart_version#g" \
    -e "s#(charts/crono-[a-z]+:)$current_re\\b#\\1$chart_version#g" "$copy"
done

for file in "${staged[@]}"; do
  copy=$(copy_of "$file")
  cmp -s -- "$copy" "$file" || cat -- "$copy" >"$file"
done

helm repo add nats https://nats-io.github.io/k8s/helm/charts/ --force-update >/dev/null
helm dependency update charts/crono-stack >/dev/null
helm-docs --log-level warning --chart-search-root charts --template-files README.md.gotmpl
scripts/ci/check-chart-versions.sh --expected "$chart_version"
echo "bumped charts to $chart_version for crono $version (server $server_digest, web $web_digest)"
