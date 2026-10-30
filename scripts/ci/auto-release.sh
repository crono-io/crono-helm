#!/usr/bin/env bash
# Release step of .github/workflows/auto-release.yml: make sure GitHub release
# VERSION exists for the tested main commit SHA and dispatch publish-charts.yml
# on its tag. publish-charts.yml is idempotent (existing signed charts are kept),
# so a re-run after a failed or cancelled dispatch resumes publishing.
#
#   - no release yet: the tag, if any, must point at SHA; create the release at
#     SHA, then dispatch publishing;
#   - release exists, tag at SHA: dispatch publishing again (recovery);
#   - release exists, tag at an earlier commit: a later main commit with the
#     same chart version. Skip when charts/ is unchanged since the tag; fail
#     when it changed (chart content changed without a version bump).
#
# Automatic runs (EVENT_NAME=workflow_run) release only charts produced from a
# real crono release: charts/crono-stack/Chart.yaml must carry the
# `crono/source-commit` annotation written by scripts/ci/bump-release.sh.
# Without it the run logs a notice and exits 0 (no release, no dispatch).
# Manual runs (workflow_dispatch) skip this gate.
#
# Env: EVENT_NAME (workflow_run | workflow_dispatch), VERSION (chart version),
# SHA (40 hex), GITHUB_REPOSITORY, GITHUB_REPOSITORY_OWNER, GH_TOKEN. Needs gh
# and git (full history); runs from the checkout of SHA.
set -euo pipefail

: "${EVENT_NAME:?}" "${VERSION:?}" "${SHA:?}" "${GITHUB_REPOSITORY:?}" "${GITHUB_REPOSITORY_OWNER:?}"
[[ $VERSION =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || { echo "::error::invalid VERSION '$VERSION'"; exit 1; }
[[ $SHA =~ ^[0-9a-f]{40}$ ]] || { echo "::error::invalid SHA '$SHA'"; exit 1; }
repo=$GITHUB_REPOSITORY

case $EVENT_NAME in
  workflow_dispatch) ;;
  workflow_run)
    source_commit=$(awk '/^annotations:/ { a = 1; next } a && /^[^[:space:]#]/ { a = 0 }
      a && /^  crono\/source-commit:/ { v = $2; gsub(/"/, "", v); print v; exit }' charts/crono-stack/Chart.yaml)
    if [[ ! $source_commit =~ ^[0-9a-f]{40}$ ]]; then
      echo "::notice::charts/crono-stack/Chart.yaml at $SHA has no crono/source-commit annotation (not produced by a crono release bump); not releasing $VERSION automatically. Run Auto Release by hand to release it."
      exit 0
    fi
    echo "Charts at $SHA come from crono source commit $source_commit."
    ;;
  *) echo "::error::unsupported EVENT_NAME '$EVENT_NAME'"; exit 1 ;;
esac

# tag_commit: commit the tag VERSION points at (peeled for annotated tags),
# empty when there is no tag. A lookup failure aborts the run: the REST commits
# endpoint printed its 422 error body for a missing tag, which then passed as a
# "tag at another commit".
tag_commit() {
  local refs
  refs=$(git ls-remote --tags "https://github.com/$repo" "refs/tags/$VERSION" "refs/tags/$VERSION^{}")
  awk -v t="refs/tags/$VERSION" '$2 == t "^{}" { peeled = $1 } $2 == t { direct = $1 }
    END { print (peeled != "" ? peeled : direct) }' <<<"$refs"
}

if gh release view "$VERSION" --repo "$repo" >/dev/null 2>&1; then
  tagged=$(tag_commit)
  [[ $tagged =~ ^[0-9a-f]{40}$ ]] || { echo "::error::release $VERSION exists but its tag cannot be resolved"; exit 1; }
  if [[ $tagged != "$SHA" ]]; then
    if git diff --quiet "$tagged" "$SHA" -- charts; then
      echo "Release $VERSION is at $tagged; charts unchanged in $SHA, nothing to release."
      exit 0
    fi
    echo "::error::charts changed since release $VERSION ($tagged) but $SHA keeps chart version $VERSION"
    exit 1
  fi
  echo "Release $VERSION exists at $SHA; dispatching publishing again (idempotent)."
else
  tagged=$(tag_commit)
  if [[ -n $tagged && $tagged != "$SHA" ]]; then
    echo "::error::tag $VERSION exists at $tagged, not at the tested commit $SHA"
    exit 1
  fi
  appversion=$(awk '/^appVersion:/ { gsub(/"/, "", $2); print $2; exit }' charts/crono-stack/Chart.yaml)
  notes=$(printf '%s\n\n%s\n' \
    "crono-server, crono-web and crono-stack $VERSION (crono $appversion), released after Charts CI passed on $SHA." \
    "Charts: oci://ghcr.io/${GITHUB_REPOSITORY_OWNER,,}/charts, signed by publish-charts.yml (see README).")
  gh release create "$VERSION" --repo "$repo" --target "$SHA" --title "crono-helm $VERSION" --notes "$notes"
fi

gh workflow run publish-charts.yml --repo "$repo" --ref "$VERSION" -f version="$VERSION"
echo "Dispatched publish-charts.yml for $VERSION."
