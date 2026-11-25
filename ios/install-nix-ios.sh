#!/usr/bin/env bash
# Installer skeleton for Nix on rootless jailbroken iOS
# (On device, ensure /var/jb/usr/bin is on PATH, or run: bash install-nix-ios.sh)
#
# Usage (on device, jailbreak active, /var/jb present):
#   ./ios/install-nix-ios.sh
#   # or after extracting a release tarball:
#   ./install.sh
#
# Prefers a local tarball from nix-build (ios/bootstrap.nix -A installer).
# Falls back to copying env + nix.conf templates for a manual bring-up.

set -e

JB_PREFIX="/var/jb"
NIX_PREFIX="${JB_PREFIX}/nix"
STORE_DIR="${NIX_PREFIX}/store"
STATE_DIR="${NIX_PREFIX}/var/nix"
LOG_DIR="${NIX_PREFIX}/var/log/nix"
CONF_DIR="${NIX_PREFIX}/etc/nix"

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}==>${NC} $1"; }
success() { echo -e "${GREEN}==>${NC} $1"; }
warning() { echo -e "${YELLOW}Warning:${NC} $1"; }
error() { echo -e "${RED}Error:${NC} $1" >&2; }
die() { error "$1"; exit 1; }

echo ""
echo "╔════════════════════════════════════════════╗"
echo "║  Nix for rootless iOS (/var/jb/nix)       ║"
echo "╚════════════════════════════════════════════╝"
echo ""

info "Checking environment..."

ARCH=$(uname -m)
case "$ARCH" in
  arm64|aarch64) ;;
  *) die "aarch64/arm64 only (detected: $ARCH)" ;;
esac

if [ ! -d "$JB_PREFIX" ] && [ ! -L "$JB_PREFIX" ]; then
  die "$JB_PREFIX not found. Activate a rootless jailbreak first."
fi

# Prefer executable path under the jb prefix when resolving tools
if [ -x "${JB_PREFIX}/usr/bin/bash" ]; then
  :
fi

success "Rootless prefix OK ($JB_PREFIX), arch=$ARCH"

# If this script is inside an extracted bootstrap tarball, delegate to install.sh
if [ -f "${SCRIPT_DIR}/install.sh" ] && [ -d "${SCRIPT_DIR}/store" ]; then
  info "Found bootstrap tarball contents; running install.sh..."
  exec "${SCRIPT_DIR}/install.sh"
fi

# If a built result tarball exists next to the repo checkout (dev workflow)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
TARBALL=""
for candidate in \
  "${REPO_ROOT}/result/nix-ios-jb-aarch64.tar.gz" \
  "${REPO_ROOT}/result/tarball.tar.gz" \
  "${SCRIPT_DIR}/nix-ios-jb-aarch64.tar.gz"
do
  if [ -f "$candidate" ]; then
    TARBALL=$candidate
    break
  fi
done

if [ -n "$TARBALL" ]; then
  info "Extracting $TARBALL..."
  TMP_DIR="${JB_PREFIX}/tmp/nix-install-$$"
  mkdir -p "$TMP_DIR"
  tar -xzf "$TARBALL" -C "$TMP_DIR"
  if [ -f "$TMP_DIR/tarball/install.sh" ]; then
    cd "$TMP_DIR/tarball"
    exec ./install.sh
  elif [ -f "$TMP_DIR/install.sh" ]; then
    cd "$TMP_DIR"
    exec ./install.sh
  else
    die "Tarball extracted but install.sh not found"
  fi
fi

# Skeleton / manual bring-up: directories + conf + env only (no store closure yet)
warning "No installer tarball found."
warning "Creating directory layout + config only (skeleton mode)."
echo ""
info "Build Stage 2 on an aarch64-darwin Mac first:"
echo "  nix-build --store 'local?root=/tmp/ios-stage2&store=/var/jb/nix/store' ios/bootstrap.nix -A installer"
echo "Then copy result/nix-ios-jb-aarch64.tar.gz to the device and re-run."
echo ""

mkdir -p "$STORE_DIR"
mkdir -p "$STATE_DIR/db"
mkdir -p "$STATE_DIR/gcroots"
mkdir -p "$STATE_DIR/profiles/per-user/${USER:-mobile}"
mkdir -p "$STATE_DIR/temproots"
mkdir -p "$LOG_DIR/drvs"
mkdir -p "$CONF_DIR"

if [ -f "${SCRIPT_DIR}/nix.conf.template" ]; then
  cp "${SCRIPT_DIR}/nix.conf.template" "$CONF_DIR/nix.conf"
  success "Installed nix.conf (allow-symlinked-store enabled)"
else
  cat > "$CONF_DIR/nix.conf" << 'EOF'
build-users-group =
sandbox = false
allow-symlinked-store = true
max-jobs = auto
cores = 0
substituters =
trusted-public-keys =
EOF
  success "Wrote minimal nix.conf"
fi

cp "${SCRIPT_DIR}/ios-nix-env.sh" "$CONF_DIR/ios-nix-env.sh"
chmod 644 "$CONF_DIR/ios-nix-env.sh"

ln -sfn "$STATE_DIR/profiles/per-user/${USER:-mobile}/profile" \
  "$STATE_DIR/profiles/default" || true

success "Skeleton layout ready under $NIX_PREFIX"
echo ""
echo "Next:"
echo "  source $CONF_DIR/ios-nix-env.sh"
echo "  # then install a real store closure from the bootstrap tarball"
echo ""
echo "Remember: binaries need iOS-appropriate linkage and ad-hoc codesign."
