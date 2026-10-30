#!/usr/bin/env bash
# Check that every chart in this repository is released in lockstep:
#   - charts/crono-server, charts/crono-web and charts/crono-stack share one
#     SemVer `version` and one `appVersion`;
#   - crono-stack depends on crono-server and crono-web at exactly that version;
#   - with --expected X.Y.Z (release workflow), that version is X.Y.Z.
#
# Usage: scripts/ci/check-chart-versions.sh [--expected X.Y.Z]
# Read-only; shared by CI, validate.sh and the publish workflow.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
expected=""
case $# in
  0) ;;
  2) [[ $1 == --expected ]] || { echo "usage: $0 [--expected X.Y.Z]" >&2; exit 2; }; expected=$2 ;;
  *) echo "usage: $0 [--expected X.Y.Z]" >&2; exit 2 ;;
esac

semver='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
components=(crono-server crono-web)
umbrella=crono-stack

fail() { echo "chart versions: $*" >&2; exit 1; }

# top_level FILE KEY: value of an unindented `KEY:` line, quotes stripped.
top_level() {
  awk -v key="$2" '
    $0 ~ "^" key ":" {
      sub("^" key ":[[:space:]]*", ""); sub(/[[:space:]]+#.*$/, ""); gsub(/^["\047]|["\047]$/, "")
      print; found++
    }
    END { if (found != 1) exit 1 }' "$1" || fail "$1 must define exactly one top-level $2"
}

# dependency_version FILE NAME: version of the dependency entry named NAME.
dependency_version() {
  awk -v want="$2" '
    /^dependencies:/ { in_deps = 1; next }
    in_deps && /^[^[:space:]-]/ { in_deps = 0 }
    !in_deps { next }
    /^[[:space:]]*-[[:space:]]/ { flush(); name = ""; version = "" }
    { line = $0; sub(/^[[:space:]]*-?[[:space:]]*/, "", line); sub(/[[:space:]]+#.*$/, "", line) }
    line ~ /^name:/ { sub(/^name:[[:space:]]*/, "", line); gsub(/["\047]/, "", line); name = line }
    line ~ /^version:/ { sub(/^version:[[:space:]]*/, "", line); gsub(/["\047]/, "", line); version = line }
    function flush() { if (name == want) { print version; count++ } }
    END { flush(); if (count != 1) exit 1 }' "$1" || fail "$1 must list dependency $2 exactly once"
}

version=$(top_level "$root/charts/$umbrella/Chart.yaml" version)
app_version=$(top_level "$root/charts/$umbrella/Chart.yaml" appVersion)
[[ $version =~ $semver ]] || fail "$umbrella version '$version' is not X.Y.Z"
if [[ -n $expected && $version != "$expected" ]]; then
  fail "$umbrella is at $version, release requested $expected"
fi

for chart in "${components[@]}"; do
  file="$root/charts/$chart/Chart.yaml"
  [[ $(top_level "$file" name) == "$chart" ]] || fail "$file: name is not $chart"
  chart_version=$(top_level "$file" version)
  [[ $chart_version == "$version" ]] || fail "$chart is at $chart_version, $umbrella at $version"
  chart_app=$(top_level "$file" appVersion)
  [[ $chart_app == "$app_version" ]] || fail "$chart appVersion $chart_app, $umbrella appVersion $app_version"
  dep_version=$(dependency_version "$root/charts/$umbrella/Chart.yaml" "$chart")
  [[ $dep_version == "$version" ]] || fail "$umbrella depends on $chart $dep_version, expected $version"
done

echo "ok: crono-server, crono-web and crono-stack aligned at $version (appVersion $app_version)"
