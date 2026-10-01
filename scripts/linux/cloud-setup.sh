#!/bin/bash
# Setup script for the localvoxtral cloud environment at claude.ai/code. Paste
# this file into the environment's Setup script field; it runs as root on the
# Ubuntu 24.04 x86_64 VM before the repository is guaranteed to be there, so
# it reads nothing from the repo. The VM snapshot after it keeps the toolchain
# for later sessions.
#
# It installs the swift.org 6.2.0 toolchain that ci.yml's `linux` job runs
# (swift:6.2.0-bookworm) and what scripts/core-tests-linux.sh needs besides:
# python3, ps and curl for the VibeRemoteShimTests and usage tests.
#
# Network: download.swift.org is not in the Trusted list (swift.org is), so the
# environment needs Custom access with download.swift.org plus the default list.
set -euo pipefail

version=6.2
tarball="swift-${version}-RELEASE-ubuntu24.04.tar.gz"
url="https://download.swift.org/swift-${version}-release/ubuntu2404/swift-${version}-RELEASE/${tarball}"
sha256=8e3d63a3371caad495e694414b9b9a22c5f68c6473077406c7296472a41bc077
prefix=/opt/swift-${version}

# Swift's Ubuntu 24.04 runtime dependencies, from swift.org's install guide.
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -qq -y --no-install-recommends \
  binutils git gnupg2 libc6-dev libcurl4-openssl-dev libedit2 libgcc-13-dev \
  libncurses-dev libpython3-dev libsqlite3-0 libstdc++-13-dev libxml2-dev \
  libz3-dev pkg-config tzdata unzip zlib1g-dev \
  python3 procps curl ca-certificates >/dev/null

if ! "$prefix/usr/bin/swift" --version 2>/dev/null | grep -q "Swift version ${version}"; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL --retry 3 -o "$tmp/$tarball" "$url"
  echo "$sha256  $tmp/$tarball" | sha256sum -c --quiet
  rm -rf "$prefix"
  mkdir -p "$prefix"
  tar -xzf "$tmp/$tarball" -C "$prefix" --strip-components=1
fi

# Only Swift's own tools go on PATH: the toolchain's clang and lld would shadow
# the VM's.
for tool in "$prefix"/usr/bin/swift*; do
  ln -sf "$tool" "/usr/local/bin/$(basename "$tool")"
done
swift --version
