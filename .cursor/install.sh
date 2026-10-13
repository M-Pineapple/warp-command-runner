#!/usr/bin/env bash
# Cloud Agent bootstrap for Warp Command Runner on Ubuntu.
# Idempotent: apt packages, Swift 6.4.1 on PATH, the macOS test path
# /private/tmp, then package resolve and the swift-sdk patch.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

export DEBIAN_FRONTEND=noninteractive

sudo apt-get update -qq
sudo apt-get install -y -qq \
    binutils \
    ca-certificates \
    curl \
    git \
    gnupg2 \
    libc6-dev \
    libcurl4-openssl-dev \
    libedit2 \
    libgcc-13-dev \
    libncurses-dev \
    libpython3-dev \
    libsqlite3-0 \
    libsqlite3-dev \
    libstdc++-13-dev \
    libxml2-dev \
    libz3-dev \
    pkg-config \
    python3 \
    tzdata \
    unzip \
    zlib1g-dev

SWIFT_VERSION="6.4.1"
if command -v swift >/dev/null 2>&1 && swift --version 2>/dev/null | head -n 1 | grep -q "Swift version ${SWIFT_VERSION} "; then
    echo "Swift ${SWIFT_VERSION} already installed"
else
    SWIFT_SIGNING_KEY="52BB7E3DE28A71BE22EC05FFEF80A866B47A981F"
    SWIFT_BRANCH="swift-${SWIFT_VERSION}-release"
    SWIFT_TAG="swift-${SWIFT_VERSION}-RELEASE"
    SWIFT_PLATFORM="ubuntu24.04"
    SWIFT_WEBROOT="https://download.swift.org"
    case "$(dpkg --print-architecture)" in
        amd64) OS_ARCH_SUFFIX="" ;;
        arm64) OS_ARCH_SUFFIX="-aarch64" ;;
        *) echo "unsupported architecture: $(dpkg --print-architecture)" >&2; exit 1 ;;
    esac
    SWIFT_WEBDIR="${SWIFT_WEBROOT}/${SWIFT_BRANCH}/$(echo "$SWIFT_PLATFORM" | tr -d .)${OS_ARCH_SUFFIX}"
    SWIFT_BIN_URL="${SWIFT_WEBDIR}/${SWIFT_TAG}/${SWIFT_TAG}-${SWIFT_PLATFORM}${OS_ARCH_SUFFIX}.tar.gz"
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    curl -fL --retry 3 --retry-delay 2 -o "$work/swift.tar.gz" "$SWIFT_BIN_URL"
    curl -fL --retry 3 --retry-delay 2 -o "$work/swift.tar.gz.sig" "${SWIFT_BIN_URL}.sig"
    GNUPGHOME="$(mktemp -d)"
    export GNUPGHOME
    gpg --batch --quiet --keyserver keyserver.ubuntu.com --recv-keys "$SWIFT_SIGNING_KEY"
    gpg --batch --verify "$work/swift.tar.gz.sig" "$work/swift.tar.gz"
    sudo tar -xzf "$work/swift.tar.gz" --directory / --strip-components=1
    sudo chmod -R o+r /usr/lib/swift
    rm -rf "$GNUPGHOME"
    unset GNUPGHOME
    rm -rf "$work"
    trap - EXIT
    swift --version
fi

# ProcessRunnerTests expects this macOS path to be a real directory.
# A symlink to /tmp is not enough: Foundation resolves it and pwd prints /tmp.
if [[ ! -d /private/tmp || -L /private/tmp ]]; then
    sudo rm -rf /private/tmp
    sudo mkdir -p /private
    sudo mkdir -m 1777 /private/tmp
fi

swift package resolve
./scripts/patch-swift-sdk.sh
echo "install complete"
