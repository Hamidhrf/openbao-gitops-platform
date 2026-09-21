#!/usr/bin/env bash
# Install pinned CLI versions into .bin/ and verify their SHA-256 checksums.
# Linux x86_64 only. Safe to run again; it replaces the binaries in .bin/.
set -euo pipefail

KIND_VERSION=v0.33.0
KIND_SHA256=aee6151561422756b764a4ae28e7f44cda5af5a9eead3cc9985112b1de8d8e0d

KUBECTL_VERSION=v1.36.4
KUBECTL_SHA256=8b8f088da2dab964f853b38464033b1be15ede2839eca751482357c45abdd05a

FLUX_VERSION=2.9.5
FLUX_SHA256=b853df82adfd7736f580692f9f734473d571606307139f8fd20c2a80dd1ff473

SOPS_VERSION=v3.13.3
SOPS_SHA256=e5bec3346a873ae91d871550f3e698c1aad962aff462a080e40f25fde17fef6b

# age publishes no checksum file. This hash was taken from the release
# tarball when the version was pinned.
AGE_VERSION=v1.3.2
AGE_SHA256=cbe24006683f8eb669266162894b9a522a1af52f2665fbc63a4bb032ed26ac10

if [ "$(uname -s)-$(uname -m)" != "Linux-x86_64" ]; then
  echo "This script supports Linux x86_64 only." >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin_dir="$repo_root/.bin"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# download <url> <file name> <expected sha256>
download() {
  curl -fsSL --retry 3 -o "$tmp/$2" "$1"
  echo "$3  $tmp/$2" | sha256sum --check --quiet
}

mkdir -p "$bin_dir"

download "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-amd64" kind "$KIND_SHA256"
install -m 0755 "$tmp/kind" "$bin_dir/kind"

download "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" kubectl "$KUBECTL_SHA256"
install -m 0755 "$tmp/kubectl" "$bin_dir/kubectl"

download "https://github.com/fluxcd/flux2/releases/download/v${FLUX_VERSION}/flux_${FLUX_VERSION}_linux_amd64.tar.gz" flux.tar.gz "$FLUX_SHA256"
tar -xzf "$tmp/flux.tar.gz" -C "$tmp" flux
install -m 0755 "$tmp/flux" "$bin_dir/flux"

download "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.amd64" sops "$SOPS_SHA256"
install -m 0755 "$tmp/sops" "$bin_dir/sops"

download "https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/age-${AGE_VERSION}-linux-amd64.tar.gz" age.tar.gz "$AGE_SHA256"
tar -xzf "$tmp/age.tar.gz" -C "$tmp" age/age age/age-keygen
install -m 0755 "$tmp/age/age" "$bin_dir/age"
install -m 0755 "$tmp/age/age-keygen" "$bin_dir/age-keygen"

echo "Installed into $bin_dir:"
"$bin_dir/kind" version
"$bin_dir/kubectl" version --client
"$bin_dir/flux" --version
"$bin_dir/sops" --version --disable-version-check
"$bin_dir/age" --version
