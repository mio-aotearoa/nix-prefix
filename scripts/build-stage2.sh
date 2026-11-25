#!/usr/bin/env bash
# Pure dramforever Stage-2 bootstrap for Termux (Android Bionic + /data/data/com.termux/files/nix/store)
#
# Implements https://dram.page/p/bootstrapping-nix/:
#   - Flavor 0 (host Nix): lives in /nix/store, operates on /nix/store
#   - Flavor 1 (Stage 1):  uses Nix with --store 'local?root=<stage>&store=/data/data/com.termux/files/nix/store'
#                          (saving one Stage-1 Nix build per dramforever's edit, or run using .#nix-stage1)
#   - Flavor 2 (Stage 2):  evaluates bootstrap.nix with builtins.storeDir == /data/data/com.termux/files/nix/store,
#                          compiling genuine Android Bionic binaries + Home Manager + all stdenv stages
#                          using the project's single fixed aarch64 ISA (armv8.2-a), with ZERO patchelf hacks!

set -euo pipefail

ARCH="aarch64"
STAGE_ROOT="${STAGE_ROOT:-$PWD/result/stage2-root}"
OUT_DIR="$PWD/result"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--arch) ARCH="$2"; shift 2 ;;
    --stage-root) STAGE_ROOT="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [-a aarch64|armv7l|x86_64|i686] [--stage-root DIR]"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

STORE_DIR="/data/data/com.termux/files/nix/store"
mkdir -p "$STAGE_ROOT" "$OUT_DIR/$ARCH"

NIXPKGS_PATH="$(nix --extra-experimental-features 'nix-command flakes' eval --raw --impure --expr '(builtins.getFlake (toString ./.)).inputs.nixpkgs.outPath')"
STORE_URI="local?root=${STAGE_ROOT}&store=${STORE_DIR}"

echo "============================================================"
echo "dramforever Pure Stage-2 Prefixed Nix Bootstrap (Bionic)"
echo "  StoreDir:   $STORE_DIR"
echo "  Stage root: $STAGE_ROOT"
echo "  Target:     $ARCH (Android Bionic, fixed ISA)"
echo "  Nixpkgs:    $NIXPKGS_PATH"
echo "============================================================"

nix-build --store "$STORE_URI" \
  --option substituters "" \
  --option sandbox false \
  bootstrap.nix \
  -A "installer.${ARCH}" \
  --arg nixpkgs "$NIXPKGS_PATH" \
  -o "$OUT_DIR/$ARCH/installer" 2>&1 | tee "$OUT_DIR/$ARCH/build.log"

TARBALL="$(find -L "$OUT_DIR/$ARCH/installer" -maxdepth 1 -name 'nix-termux-*.tar.gz' -type f | head -n 1)"
if [ -n "$TARBALL" ]; then
  cp -f "$TARBALL" "$OUT_DIR/nix-termux-${ARCH}.tar.gz"
  echo "Pure Stage-2 tarball ready: $OUT_DIR/nix-termux-${ARCH}.tar.gz"
fi
