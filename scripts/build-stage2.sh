#!/usr/bin/env bash
# Pure dramforever Stage-2 bootstrap for Termux (Android Bionic + /data/data/com.termux/files/nix/store)
#
# Implements https://dram.page/p/bootstrapping-nix/:
#   - Flavor 0 (host Nix): lives in /nix/store, operates on /nix/store
#   - Flavor 1 (Stage 1):  Nix targeting /data/data/com.termux/files/nix/store
#                          - Direct mode (--direct, or when /data/data/com.termux/files/nix is writable):
#                            builds directly in /data/data/com.termux/files/nix/store with ZERO
#                            diverted-store / user-namespace requirement (works on Ubuntu 24.04 CI!)
#                          - Diverted mode (--stage-root DIR):
#                            uses `local?root=<stage>&store=/data/data/com.termux/files/nix/store`
#                            on hosts with unprivileged user namespaces (e.g. NixOS dev machines)
#   - Flavor 2 (Stage 2):  evaluates bootstrap.nix with builtins.storeDir == /data/data/com.termux/files/nix/store,
#                          compiling genuine Android Bionic binaries + Home Manager + all stdenv stages
#                          using the project's single fixed aarch64 ISA (armv8.2-a), with ZERO patchelf hacks!

set -euo pipefail

ARCH="aarch64"
STAGE_ROOT=""
DIRECT_MODE="auto"
OUT_DIR="$PWD/result"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--arch) ARCH="$2"; shift 2 ;;
    --direct) DIRECT_MODE="yes"; shift ;;
    --stage-root) STAGE_ROOT="$2"; DIRECT_MODE="no"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [-a aarch64|armv7l|x86_64|i686] [--direct | --stage-root DIR]"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

NIX_PREFIX="/data/data/com.termux/files/nix"
STORE_DIR="${NIX_PREFIX}/store"
STATE_DIR="${NIX_PREFIX}/var/nix"
LOG_DIR="${NIX_PREFIX}/var/log/nix"
mkdir -p "$OUT_DIR/$ARCH"

if [ "$DIRECT_MODE" = "auto" ]; then
  if [ -d "$NIX_PREFIX" ] && [ -w "$NIX_PREFIX" ]; then
    DIRECT_MODE="yes"
  else
    DIRECT_MODE="no"
  fi
fi

NIXPKGS_PATH="$(nix --extra-experimental-features 'nix-command flakes' eval --raw --impure --expr '(builtins.getFlake (toString ./.)).inputs.nixpkgs.outPath')"

if [ "$DIRECT_MODE" = "yes" ]; then
  mkdir -p "$STORE_DIR" "$STATE_DIR" "$LOG_DIR" "${NIX_PREFIX}/etc/nix"
  STORE_URI="local?store=${STORE_DIR}&state=${STATE_DIR}&log=${LOG_DIR}"
  NIX_BUILD_OPTS=(
    --option substituters ""
    --option sandbox false
    --option filter-syscalls false
  )
  MODE_DESC="direct (${NIX_PREFIX}, no userns required)"
else
  STAGE_ROOT="${STAGE_ROOT:-$PWD/result/stage2-root}"
  mkdir -p "$STAGE_ROOT"
  STORE_URI="local?root=${STAGE_ROOT}&store=${STORE_DIR}"
  NIX_BUILD_OPTS=(
    --option substituters ""
  )
  MODE_DESC="diverted chroot-root (${STAGE_ROOT})"
fi

echo "============================================================"
echo "dramforever Pure Stage-2 Prefixed Nix Bootstrap (Bionic)"
echo "  Mode:       $MODE_DESC"
echo "  StoreDir:   $STORE_DIR"
echo "  Store URI:  $STORE_URI"
echo "  Target:     $ARCH (Android Bionic, fixed ISA)"
echo "  Nixpkgs:    $NIXPKGS_PATH"
echo "============================================================"

# Seed nixpkgs minimal-bootstrap fixed-output source tree (stage0-posix-*-source) into the
# custom Stage-2 store. On x86_64-linux / i686-linux, nixpkgs bootstraps from minimal-bootstrap
# whose directory-NAR FOD cannot be fetched by builtin:fetchurl without a substituter for this storeDir.
echo "Seeding minimal-bootstrap source tree into $STORE_DIR..."
MINBOOT_SRC="$(nix-build "$NIXPKGS_PATH" -A make-minimal-bootstrap-sources --no-out-link)"
MINBOOT_NAME="$(basename "$MINBOOT_SRC" | sed 's/^[0-9a-z]\{32\}-//')"
SEED_TMP="$(mktemp -d)"
cp -a "$MINBOOT_SRC" "$SEED_TMP/$MINBOOT_NAME"
SEEDED_PATH="$(nix-store --store "$STORE_URI" --add-fixed --recursive sha256 "$SEED_TMP/$MINBOOT_NAME")"
chmod -R u+w "$SEED_TMP" 2>/dev/null || true
rm -rf "$SEED_TMP"
echo "  Seeded: $SEEDED_PATH"

NIX_BUILD_BIN="nix-build"
if [ "$DIRECT_MODE" = "yes" ] && [ -x "$OUT_DIR/nix-stage1/bin/nix-build" ]; then
  NIX_BUILD_BIN="$OUT_DIR/nix-stage1/bin/nix-build"
  echo "Using Stage-1 Nix driver: $NIX_BUILD_BIN"
fi

"$NIX_BUILD_BIN" --store "$STORE_URI" \
  "${NIX_BUILD_OPTS[@]}" \
  bootstrap.nix \
  -A "installer.${ARCH}" \
  --arg nixpkgs "$NIXPKGS_PATH" \
  -o "$OUT_DIR/$ARCH/installer" 2>&1 | tee "$OUT_DIR/$ARCH/build.log"

TARBALL="$(find -L "$OUT_DIR/$ARCH/installer" -maxdepth 1 -name 'nix-termux-*.tar.gz' -type f | head -n 1)"
if [ -n "$TARBALL" ]; then
  cp -f "$TARBALL" "$OUT_DIR/nix-termux-${ARCH}.tar.gz"
  echo "Pure Stage-2 tarball ready: $OUT_DIR/nix-termux-${ARCH}.tar.gz"
fi
