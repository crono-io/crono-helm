#!/usr/bin/env bash
# Resolve and validate the crono release that triggered
# .github/workflows/release-bump-pr.yml. Every value is read from the event JSON
# with jq and checked against a strict pattern before it is written out; no
# event value is ever evaluated as shell or interpolated into a workflow script.
#
# Env:
#   GITHUB_EVENT_NAME  repository_dispatch | workflow_dispatch
#   GITHUB_EVENT_PATH  event JSON
#   GITHUB_OUTPUT      receives key=value lines (default: stdout)
#
# repository_dispatch (`crono-release`, sent by crono-io/crono
# .github/workflows/dispatch-helm-release.yml):
#   client_payload.{version, source_sha, server_digest, web_digest}
# workflow_dispatch: inputs.{version, source_sha, server_digest, web_digest}
#   and the optional inputs.chart_version.
#
# version: X.Y.Z (a leading v is stripped); source_sha: 40 lowercase hex;
# digests: sha256:<64 lowercase hex>; chart_version: X.Y.Z or empty.
# Outputs: version, chart_version, source_sha, server_digest, web_digest.
#
# Fixtures: scripts/ci/release-events/*.json (checked by validate.sh).
set -euo pipefail

semver='^[0-9]+\.[0-9]+\.[0-9]+$'
sha_re='^[0-9a-f]{40}$'
digest_re='^sha256:[0-9a-f]{64}$'

die() { echo "release-event: $*" >&2; exit 1; }

command -v jq >/dev/null || die "jq is required"
event=${GITHUB_EVENT_PATH:?GITHUB_EVENT_PATH is required}
[[ -f $event ]] || die "event file not found"
jq -e 'type == "object"' "$event" >/dev/null 2>&1 || die "event is not a JSON object"

# field PATH: the string at the dotted jq PATH, empty when absent or null.
# Non-strings and strings with control characters are refused.
field() {
  local value
  value=$(jq -r --arg p "$1" '
    getpath($p | split(".")) as $v
    | if $v == null then ""
      elif ($v | type) != "string" then error("not a string")
      elif ($v | test("[\u0000-\u001f\u007f]")) then error("control character")
      else $v end' "$event" 2>/dev/null) || die "$1 must be a single-line string"
  printf '%s' "$value"
}

case ${GITHUB_EVENT_NAME:-} in
  repository_dispatch)
    action=$(field action)
    [[ $action == crono-release ]] || die "unexpected repository_dispatch type '$action'"
    prefix=client_payload
    chart_version=""
    ;;
  workflow_dispatch)
    prefix=inputs
    chart_version=$(field inputs.chart_version)
    chart_version=${chart_version#v}
    [[ -z $chart_version || $chart_version =~ $semver ]] || die "inputs.chart_version must be X.Y.Z or empty"
    ;;
  *)
    die "unsupported event '${GITHUB_EVENT_NAME:-}'"
    ;;
esac

raw_version=$(field "$prefix.version")
version=${raw_version#v}
[[ $version =~ $semver ]] || die "$prefix.version must be X.Y.Z or vX.Y.Z"
source_sha=$(field "$prefix.source_sha")
[[ $source_sha =~ $sha_re ]] || die "$prefix.source_sha must be a 40-hex commit SHA"
server_digest=$(field "$prefix.server_digest")
[[ $server_digest =~ $digest_re ]] || die "$prefix.server_digest must be sha256:<64 lowercase hex>"
web_digest=$(field "$prefix.web_digest")
[[ $web_digest =~ $digest_re ]] || die "$prefix.web_digest must be sha256:<64 lowercase hex>"

{
  echo "version=$version"
  echo "chart_version=$chart_version"
  echo "source_sha=$source_sha"
  echo "server_digest=$server_digest"
  echo "web_digest=$web_digest"
} >>"${GITHUB_OUTPUT:-/dev/stdout}"
