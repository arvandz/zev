#!/usr/bin/env bash
set -euo pipefail

ZEV_REPO="arvandz/zev"
ZEV_VERSION="${ZEV_VERSION:-v0.2.0}"
ZIG_VERSION="${ZIG_VERSION:-0.17.0-dev.1567+f0354179a}"
PREFIX="${PREFIX:-/usr/local}"
BUILD_DIR="$(mktemp -d /tmp/zev-install.XXXXXX)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'

info()  { printf "${BOLD}==>${RESET} %s\n" "$1"; }
ok()    { printf "${GREEN}✓${RESET} %s\n" "$1"; }
warn()  { printf "${YELLOW}!${RESET} %s\n" "$1"; }
fail()  { printf "${RED}✗ %s${RESET}\n" "$1" >&2; exit 1; }

cleanup() { rm -rf "$BUILD_DIR"; }
trap cleanup EXIT

fetch() {
    local url="$1" out="$2"
    if ! curl -fsSL --retry 3 --retry-delay 2 "$url" -o "$out"; then
        fail "Download failed: $url"
    fi
    if [ ! -s "$out" ]; then
        fail "Downloaded file is empty: $url"
    fi
}

verify_sha256() {
    local file="$1" expected="$2"
    local actual
    if command -v sha256sum >/dev/null 2>&1; then
        actual=$(sha256sum "$file" | awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then
        actual=$(shasum -a 256 "$file" | awk '{print $1}')
    else
        warn "No sha256sum/shasum found — skipping checksum verification"
        return 0
    fi
    if [ "$actual" != "$expected" ]; then
        fail "Checksum mismatch for $file
  expected: $expected
  actual:   $actual
This usually means the download returned an error page instead of the real file."
    fi
    ok "Checksum verified"
}

detect_platform() {
    local os arch
    case "$(uname -s)" in
        Linux)  os="linux" ;;
        Darwin) os="macos" ;;
        *) fail "Unsupported OS: $(uname -s). Use WSL on Windows, or see install.ps1." ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64)  arch="x86_64" ;;
        arm64|aarch64) arch="aarch64" ;;
        *) fail "Unsupported architecture: $(uname -m)" ;;
    esac
    echo "${arch}-${os}"
}

find_system_zig() {
    if command -v zig >/dev/null 2>&1; then
        local ver
        ver=$(zig version 2>/dev/null || echo "")
        case "$ver" in
            0.17.*)
                echo "$(command -v zig)"
                return 0
                ;;
        esac
    fi
    return 1
}

main() {
    info "Zev installer"
    echo "   Version:  ${ZEV_VERSION}"
    echo "   Prefix:   ${PREFIX}"
    echo ""

    local platform zig_bin
    platform=$(detect_platform)
    info "Detected platform: ${platform}"

    if zig_bin=$(find_system_zig); then
        ok "Found compatible system Zig: ${zig_bin} ($(zig version))"
    else
        info "No compatible system Zig found — downloading pinned build"
        local zig_ext="tar.xz"
        local zig_url="https://ziglang.org/builds/zig-${platform}-${ZIG_VERSION}.${zig_ext}"
        local zig_archive="${BUILD_DIR}/zig.${zig_ext}"

        info "Downloading Zig ${ZIG_VERSION} for ${platform}..."
        fetch "$zig_url" "$zig_archive"

        if command -v file >/dev/null 2>&1; then
            local ftype
            ftype=$(file -b "$zig_archive")
            case "$ftype" in
                *XZ*|*xz*) ok "Downloaded file verified as XZ archive" ;;
                *)
                    fail "Downloaded file is not a valid archive (got: ${ftype}).
This Zig nightly build may have been pruned from ziglang.org.
Try setting ZIG_VERSION to a current build from https://ziglang.org/download/"
                    ;;
            esac
        fi

        info "Extracting Zig..."
        tar -xf "$zig_archive" -C "$BUILD_DIR"
        zig_bin=$(find "$BUILD_DIR" -maxdepth 2 -type f -name "zig" | head -1)
        [ -n "$zig_bin" ] || fail "Could not locate zig binary after extraction"
        ok "Zig ready: $("$zig_bin" version)"
    fi

    local src_dir="${BUILD_DIR}/zev-src"
    if [ -f "$(pwd)/build.zig" ] && [ -d "$(pwd)/src" ]; then
        info "Building from local source in $(pwd)"
        src_dir="$(pwd)"
    else
        info "Downloading Zev ${ZEV_VERSION} source..."
        local src_url="https://github.com/${ZEV_REPO}/archive/refs/tags/${ZEV_VERSION}.tar.gz"
        local src_archive="${BUILD_DIR}/zev-src.tar.gz"
        fetch "$src_url" "$src_archive"

        if command -v file >/dev/null 2>&1; then
            local ftype
            ftype=$(file -b "$src_archive")
            case "$ftype" in
                *gzip*|*Zip*) ok "Downloaded file verified as archive" ;;
                *) fail "Downloaded source is not a valid archive (got: ${ftype}). Check that ${ZEV_VERSION} exists at github.com/${ZEV_REPO}/releases" ;;
            esac
        fi

        mkdir -p "$src_dir"
        tar -xzf "$src_archive" -C "$src_dir" --strip-components=1
        ok "Source extracted"
    fi

    info "Building Zev (ReleaseSafe)..."
    (cd "$src_dir" && "$zig_bin" build -Doptimize=ReleaseSafe)
    [ -f "${src_dir}/zig-out/bin/zev" ] || fail "Build did not produce zig-out/bin/zev"
    ok "Build complete"

    local install_dir="${PREFIX}/bin"
    if mkdir -p "$install_dir" 2>/dev/null && [ -w "$install_dir" ]; then
        cp "${src_dir}/zig-out/bin/zev" "${install_dir}/zev"
        chmod +x "${install_dir}/zev"
    elif command -v sudo >/dev/null 2>&1; then
        info "Installing to ${install_dir} (requires sudo)"
        sudo mkdir -p "$install_dir"
        sudo cp "${src_dir}/zig-out/bin/zev" "${install_dir}/zev"
        sudo chmod +x "${install_dir}/zev"
    else
        fail "Cannot write to ${install_dir} and no sudo available.
Set PREFIX to a writable directory, e.g.:
  PREFIX=\$HOME/.local $0"
    fi
    ok "Installed to ${install_dir}/zev"

    echo ""
    info "Verifying installation"
    if command -v zev >/dev/null 2>&1; then
        zev version
    else
        "${install_dir}/zev" version
        warn "${install_dir} is not on your PATH — add it with:"
        echo "  export PATH=\"${install_dir}:\$PATH\""
    fi

    echo ""
    ok "Zev installed successfully"
    echo ""
    echo "Quick start:"
    echo "  zev init"
    echo "  zev config set user.name 'Your Name'"
    echo "  zev add <file> && zev commit 'Initial commit'"
    echo "  zev metrics set accuracy 0.95"
    echo "  zev check HEAD"
    echo ""
}

main "$@"