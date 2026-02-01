#!/bin/bash
set -euo pipefail

# bit installer
# Usage: curl -fsSL https://raw.githubusercontent.com/mizchi/bit/main/install.sh | bash

REPO="mizchi/bit"
INSTALL_DIR="${BIT_INSTALL_DIR:-$HOME/.local/bin}"
BINARY_NAME="bit"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info() {
    echo -e "${GREEN}[info]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[warn]${NC} $1"
}

error() {
    echo -e "${RED}[error]${NC} $1"
    exit 1
}

detect_platform() {
    local os arch

    case "$(uname -s)" in
        Linux*)  os="linux" ;;
        Darwin*) os="darwin" ;;
        MINGW*|MSYS*|CYGWIN*) error "Windows is not yet supported. Please build from source." ;;
        *) error "Unsupported OS: $(uname -s)" ;;
    esac

    case "$(uname -m)" in
        x86_64|amd64) arch="x64" ;;
        arm64|aarch64) arch="arm64" ;;
        *) error "Unsupported architecture: $(uname -m)" ;;
    esac

    # macOS: use arm64 binary (works on Intel via Rosetta)
    if [[ "$os" == "darwin" ]]; then
        echo "darwin-arm64"
    elif [[ "$os" == "linux" ]]; then
        if [[ "$arch" == "arm64" ]]; then
            error "Linux arm64 is not yet supported"
        fi
        echo "linux-x64"
    fi
}

get_latest_version() {
    local url="https://api.github.com/repos/$REPO/releases/latest"
    if command -v curl &> /dev/null; then
        curl -fsSL "$url" | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/'
    elif command -v wget &> /dev/null; then
        wget -qO- "$url" | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/'
    else
        error "Neither curl nor wget found. Please install one of them."
    fi
}

download() {
    local url="$1"
    local output="$2"

    info "Downloading from $url"
    if command -v curl &> /dev/null; then
        curl -fsSL -o "$output" "$url"
    elif command -v wget &> /dev/null; then
        wget -qO "$output" "$url"
    else
        error "Neither curl nor wget found"
    fi
}

verify_checksum() {
    local file="$1"
    local checksum_url="$2"
    local expected actual

    info "Verifying checksum..."
    download "$checksum_url" "${file}.sha256.expected"
    expected=$(cat "${file}.sha256.expected" | awk '{print $1}')

    if command -v sha256sum &> /dev/null; then
        actual=$(sha256sum "$file" | awk '{print $1}')
    elif command -v shasum &> /dev/null; then
        actual=$(shasum -a 256 "$file" | awk '{print $1}')
    else
        warn "Cannot verify checksum: sha256sum/shasum not found"
        rm -f "${file}.sha256.expected"
        return
    fi

    rm -f "${file}.sha256.expected"

    if [[ "$expected" != "$actual" ]]; then
        error "Checksum verification failed!\nExpected: $expected\nActual: $actual"
    fi
    info "Checksum verified"
}

main() {
    local platform version asset_name download_url checksum_url tmp_file

    info "Detecting platform..."
    platform=$(detect_platform)
    info "Platform: $platform"

    info "Fetching latest version..."
    version=$(get_latest_version)
    if [[ -z "$version" ]]; then
        error "Failed to get latest version"
    fi
    info "Version: $version"

    # Construct download URL
    if [[ "$platform" == "windows-x64" ]]; then
        asset_name="bit-${platform}.exe"
    else
        asset_name="bit-${platform}"
    fi
    download_url="https://github.com/$REPO/releases/download/$version/$asset_name"
    checksum_url="${download_url}.sha256"

    # Create temp file
    tmp_file=$(mktemp)
    trap "rm -f '$tmp_file'" EXIT

    # Download
    download "$download_url" "$tmp_file"

    # Verify checksum
    verify_checksum "$tmp_file" "$checksum_url"

    # Install
    info "Installing to $INSTALL_DIR/$BINARY_NAME"
    mkdir -p "$INSTALL_DIR"

    if [[ "$platform" == "windows-x64" ]]; then
        mv "$tmp_file" "$INSTALL_DIR/${BINARY_NAME}.exe"
    else
        mv "$tmp_file" "$INSTALL_DIR/$BINARY_NAME"
        chmod +x "$INSTALL_DIR/$BINARY_NAME"
    fi

    # Check PATH
    if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
        warn "$INSTALL_DIR is not in your PATH"
        echo ""
        echo "Add the following to your shell profile (.bashrc, .zshrc, etc.):"
        echo ""
        echo "  export PATH=\"\$HOME/.local/bin:\$PATH\""
        echo ""
    fi

    info "Successfully installed bit $version"
    echo ""
    echo "Run 'bit --help' to get started"
}

main "$@"
