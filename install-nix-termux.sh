#!/data/data/com.termux/files/usr/bin/bash
# One-line installer for Nix + Home Manager on Termux
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/mio-aotearoa/nix-prefix/main/install-nix-termux.sh | bash
# Or:
#   wget -qO- https://raw.githubusercontent.com/mio-aotearoa/nix-prefix/main/install-nix-termux.sh | bash

set -euo pipefail

# Configuration
REPO_OWNER="mio-aotearoa"
REPO_NAME="nix-prefix"
GITHUB_API="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest"
TERMUX_PREFIX="/data/data/com.termux/files"
NIX_PREFIX="${TERMUX_PREFIX}/nix"
CONF_DIR="${NIX_PREFIX}/etc/nix"
TMP_DIR="${TERMUX_PREFIX}/usr/tmp/nix-install-$$"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}==>${NC} $1"; }
success() { echo -e "${GREEN}==>${NC} $1"; }
warning() { echo -e "${YELLOW}Warning:${NC} $1"; }
error()   { echo -e "${RED}Error:${NC} $1" >&2; }
die()     { error "$1"; exit 1; }

cleanup() {
    rm -rf "$TMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║   Nix + Home Manager Termux Installer    ║"
echo "╠══════════════════════════════════════════╣"
echo "║  Repository: ${REPO_OWNER}/${REPO_NAME}"
echo "╚══════════════════════════════════════════╝"
echo ""

info "Checking environment..."
if [ ! -d "${TERMUX_PREFIX}" ]; then
    die "This script must be run in Termux on Android ($TERMUX_PREFIX not found)"
fi

ARCH=$(uname -m)
SUPPORTED_ARCHS=("aarch64" "armv7l" "x86_64" "i686")
if [[ ! " ${SUPPORTED_ARCHS[*]} " =~ " ${ARCH} " ]]; then
    die "Unsupported architecture: $ARCH. Supported: ${SUPPORTED_ARCHS[*]}"
fi
success "Environment check passed (${ARCH})"

info "Checking for required tools..."
MISSING_TOOLS=""
for tool in curl tar gzip; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        MISSING_TOOLS="$MISSING_TOOLS $tool"
    fi
done

if [ -n "$MISSING_TOOLS" ]; then
    warning "Missing tools:$MISSING_TOOLS"
    if command -v pkg >/dev/null 2>&1; then
        info "Installing missing tools with pkg..."
        pkg install -y $MISSING_TOOLS || die "Failed to install required tools"
    else
        die "Missing required tools:$MISSING_TOOLS"
    fi
fi
success "All required tools available"

info "Checking disk space..."
AVAILABLE_KB=$(df -Pk "${TERMUX_PREFIX}" | awk 'NR==2 {print $4}')
AVAILABLE_GB=$((AVAILABLE_KB / 1024 / 1024))
if [ "$AVAILABLE_GB" -lt 2 ]; then
    warning "Low disk space: ${AVAILABLE_GB}GB available (2GB+ recommended)"
    if [ -t 0 ]; then
        echo -n "Continue anyway? [y/N] "
        read -r response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            die "Installation cancelled by user"
        fi
    fi
else
    success "Sufficient disk space: ${AVAILABLE_GB}GB available"
fi

mkdir -p "$TMP_DIR"
cd "$TMP_DIR"

# Support installing from a local tarball via LOCAL_TARBALL env var (useful for testing/offline)
if [ -n "${LOCAL_TARBALL:-}" ]; then
    info "Using local tarball: $LOCAL_TARBALL"
    cp "$LOCAL_TARBALL" nix-termux.tar.gz
else
    info "Fetching latest release information..."
    RELEASE_JSON="$TMP_DIR/release.json"
    if ! curl -fsSL "$GITHUB_API" -o "$RELEASE_JSON"; then
        die "Failed to fetch release information from GitHub API"
    fi

    RELEASE_TAG=$(grep -o '"tag_name": *"[^"]*"' "$RELEASE_JSON" | head -1 | sed 's/"tag_name": *"\([^"]*\)"/\1/')
    DOWNLOAD_URL=$(grep -o '"browser_download_url": *"[^"]*nix-termux-'"${ARCH}"'[^"]*\.tar\.gz"' "$RELEASE_JSON" | head -1 | sed 's/"browser_download_url": *"\([^"]*\)"/\1/' || true)
    rm -f "$RELEASE_JSON"

    if [ -z "$RELEASE_TAG" ] || [ -z "$DOWNLOAD_URL" ]; then
        die "Failed to find release tarball for architecture $ARCH."
    fi

    success "Found latest release: ${RELEASE_TAG}"
    echo "  Architecture: $ARCH"
    echo "  Download URL: $DOWNLOAD_URL"

    info "Downloading Nix tarball..."
    if ! curl -fL --progress-bar "$DOWNLOAD_URL" -o nix-termux.tar.gz; then
        die "Failed to download release tarball"
    fi
    success "Download complete"
fi

info "Verifying tarball..."
if ! tar -tzf nix-termux.tar.gz >/dev/null 2>&1; then
    die "File is not a valid tar.gz archive"
fi
success "Tarball verified"

info "Extracting tarball..."
tar -xzf nix-termux.tar.gz || die "Failed to extract tarball"
success "Extraction complete"

if [ ! -f "tarball/install.sh" ]; then
    die "Installer script not found in tarball"
fi

info "Running Nix installer..."
echo ""
(cd tarball && sh ./install.sh --yes) || die "Installation failed"
echo ""
success "Nix installation completed successfully!"

# Configure shell rc to source termux-nix-env.sh
info "Setting up shell environment..."
case "${SHELL:-}" in
    */zsh) SHELL_RC="$HOME/.zshrc" ;;
    *)     SHELL_RC="$HOME/.bashrc" ;;
esac
touch "$SHELL_RC"

ENV_LINE=". \"${CONF_DIR}/termux-nix-env.sh\""
if ! grep -q "termux-nix-env.sh" "$SHELL_RC" 2>/dev/null; then
    cat >> "$SHELL_RC" << EOF

# Prefixed Nix + Home Manager environment for Termux
if [ -f "${CONF_DIR}/termux-nix-env.sh" ]; then
    ${ENV_LINE}
fi
EOF
    success "Added Nix environment hook to $SHELL_RC"
else
    info "Nix environment already configured in $SHELL_RC"
fi

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║          Installation Complete!          ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "Start using Nix + Home Manager:"
echo ""
echo -e "  ${GREEN}. ${CONF_DIR}/termux-nix-env.sh${NC}"
echo -e "  ${BLUE}nix --version${NC}"
echo -e "  ${BLUE}home-manager --version${NC}"
echo ""
echo "Initialize Home Manager:"
echo -e "  ${BLUE}termux-home-manager-init${NC}"
echo -e "  ${BLUE}home-manager switch${NC}"
echo ""
