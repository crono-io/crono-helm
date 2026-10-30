#!/usr/bin/env bash
# Install the pinned chart toolchain for linux/amd64 into DEST, verifying every
# download against a SHA-256 recorded here:
#   helm, helm-unittest (Helm plugin), kubeconform, chart-testing (ct, plus its
#   etc/ schema and lint config), kind, kubectl, helm-docs, actionlint, cosign.
#
# CI uses it; locally it is optional (validate.sh uses whatever is on PATH or in
# TOOLS_DIR). ct additionally needs `yamllint` and `yamale` (Python) on PATH.
#
# Usage: scripts/ci/install-tools.sh DEST
# Bumping a tool: update its version and copy the checksum from the project's
# release checksum file (never from a fresh local download).
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 DEST" >&2
  exit 2
fi
dest=$1
if [[ "$(uname -s)/$(uname -m)" != "Linux/x86_64" ]]; then
  echo "install-tools.sh only supports linux/amd64; install the tools manually" >&2
  exit 1
fi

HELM_VERSION=v3.22.1
HELM_SHA256=896cf63684a42a723d61c980369d6e588330927deb13676ca0d85006dd6da0ea
HELM_UNITTEST_VERSION=0.8.2
HELM_UNITTEST_SHA256=56ab3091e6fa52a7c92ee951def9bed957f295d9ce98483aed404e748d7b3a94
KUBECONFORM_VERSION=v0.8.0
KUBECONFORM_SHA256=9bc2bffbf71f261128533edaf912153948b7ff238f9a531ae6d34466ec287883
CT_VERSION=3.15.0
CT_SHA256=467561730f25fe09d5e6cd09a3e1f6aa759871c657a57602947c716d9be2c583
KIND_VERSION=v0.33.0
KIND_SHA256=aee6151561422756b764a4ae28e7f44cda5af5a9eead3cc9985112b1de8d8e0d
KUBECTL_VERSION=v1.37.0
KUBECTL_SHA256=6129359f4e1f3848a5572ccb0b26cf28b8ca08cef38c95a765b2f64a2c961a2f
HELM_DOCS_VERSION=1.14.2
HELM_DOCS_SHA256=a8cf72ada34fad93285ba2a452b38bdc5bd52cc9a571236244ec31022928d6cc
ACTIONLINT_VERSION=1.7.12
ACTIONLINT_SHA256=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8
COSIGN_VERSION=v2.6.5
COSIGN_SHA256=c3b4f5410e608af03a5eb0aaac84a4313d8da131248e08ff1759ac70c79d1644

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$dest"
dest=$(cd "$dest" && pwd)

# download URL SHA256: fetch URL into $work and verify it; prints the path only
# on success. Callers capture it with `var=$(download ...)`, where errexit does
# not apply inside the substitution, so every failure returns explicitly and the
# failing assignment then stops the script under `set -e`.
download() {
  local url=$1 sha=$2 file
  file="$work/$(basename "$url")"
  curl --fail --silent --show-error --location --retry 3 --output "$file" "$url" || return 1
  echo "$sha  $file" | sha256sum --check --quiet >&2 || return 1
  printf '%s\n' "$file"
}

# fetch_tar URL SHA256 MEMBER: extract MEMBER of a verified tarball into DEST.
fetch_tar() {
  local archive
  archive=$(download "$1" "$2")
  tar -xzf "$archive" -C "$work" "$3"
  install -m 0755 "$work/$3" "$dest/$(basename "$3")"
}

# fetch_bin URL SHA256 NAME: install a verified single binary as DEST/NAME.
fetch_bin() {
  local file
  file=$(download "$1" "$2")
  install -m 0755 "$file" "$dest/$3"
}

fetch_tar "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
  "$HELM_SHA256" linux-amd64/helm
fetch_tar "https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}/kubeconform-linux-amd64.tar.gz" \
  "$KUBECONFORM_SHA256" kubeconform
fetch_tar "https://github.com/norwoodj/helm-docs/releases/download/v${HELM_DOCS_VERSION}/helm-docs_${HELM_DOCS_VERSION}_Linux_x86_64.tar.gz" \
  "$HELM_DOCS_SHA256" helm-docs
fetch_tar "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz" \
  "$ACTIONLINT_SHA256" actionlint
fetch_bin "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-amd64" \
  "$KIND_SHA256" kind
fetch_bin "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
  "$KUBECTL_SHA256" kubectl
fetch_bin "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-amd64" \
  "$COSIGN_SHA256" cosign

# chart-testing: the binary plus etc/chart_schema.yaml and etc/lintconf.yaml,
# found through CT_CONFIG_DIR (validate.sh sets it to DEST/ct-etc).
ct_archive=$(download "https://github.com/helm/chart-testing/releases/download/v${CT_VERSION}/chart-testing_${CT_VERSION}_linux_amd64.tar.gz" "$CT_SHA256")
mkdir -p "$work/ct" "$dest/ct-etc"
tar -xzf "$ct_archive" -C "$work/ct" ct etc/chart_schema.yaml etc/lintconf.yaml
install -m 0755 "$work/ct/ct" "$dest/ct"
install -m 0644 "$work/ct/etc/chart_schema.yaml" "$work/ct/etc/lintconf.yaml" "$dest/ct-etc/"

# helm-unittest: unpack the verified release into the Helm plugin directory
# instead of `helm plugin install`, whose hook downloads an unverified binary.
plugins_dir=$("$dest/helm" env HELM_PLUGINS)
unittest_archive=$(download "https://github.com/helm-unittest/helm-unittest/releases/download/v${HELM_UNITTEST_VERSION}/helm-unittest-linux-amd64-${HELM_UNITTEST_VERSION}.tgz" "$HELM_UNITTEST_SHA256")
rm -rf "$plugins_dir/helm-unittest"
mkdir -p "$plugins_dir/helm-unittest"
tar -xzf "$unittest_archive" -C "$plugins_dir/helm-unittest" untt plugin.yaml
"$dest/helm" unittest --help >/dev/null

echo "installed into $dest: helm ${HELM_VERSION} (+unittest ${HELM_UNITTEST_VERSION} in $plugins_dir)," \
  "kubeconform ${KUBECONFORM_VERSION}, ct ${CT_VERSION}, kind ${KIND_VERSION}, kubectl ${KUBECTL_VERSION}," \
  "helm-docs ${HELM_DOCS_VERSION}, actionlint ${ACTIONLINT_VERSION}, cosign ${COSIGN_VERSION}"
