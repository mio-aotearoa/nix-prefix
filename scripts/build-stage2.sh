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

show_disk_usage() {
  df -h "$PWD"
  if [ -d "$STORE_DIR" ]; then
    df -h "$STORE_DIR"
  fi
}

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
  if unshare --user --mount true 2>/dev/null; then
    SANDBOX_OPT="true"
  else
    SANDBOX_OPT="false"
  fi
  NIX_BUILD_OPTS=(
    --option substituters ""
    --option hashed-mirrors "https://tarballs.nixos.org"
    --option sandbox "$SANDBOX_OPT"
    --option filter-syscalls false
  )
  MODE_DESC="direct (${NIX_PREFIX}, sandbox=${SANDBOX_OPT})"
else
  STAGE_ROOT="${STAGE_ROOT:-$PWD/result/stage2-root}"
  mkdir -p "$STAGE_ROOT"
  STORE_URI="local?root=${STAGE_ROOT}&store=${STORE_DIR}"
  NIX_BUILD_OPTS=(
    --option substituters ""
    --option hashed-mirrors "https://tarballs.nixos.org"
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
show_disk_usage

NIX_BUILD_BIN="nix-build"
if [ "$DIRECT_MODE" = "yes" ] && [ -x "$OUT_DIR/nix-stage1/bin/nix-build" ]; then
  NIX_BUILD_BIN="$OUT_DIR/nix-stage1/bin/nix-build"
  echo "Using Stage-1 Nix driver: $NIX_BUILD_BIN"
fi

# Instantiate the Stage-2 derivation first and pre-seed pure Fixed-Output source
# derivations (stage0-posix-*-source, config.guess, config.sub, bootstrap tarballs)
# from host /nix/store (cache.nixos.org) into the custom store via `nix-store --add-fixed`.
# This avoids upstream 502s (e.g. git.savannah.gnu.org) while compiling 100% of built
# derivations natively in /data/data/com.termux/files/nix/store.
STAGE2_DRV="$(nix-instantiate --store "$STORE_URI" bootstrap.nix -A "installer.${ARCH}" --arg nixpkgs "$NIXPKGS_PATH")"
echo "Instantiated Stage-2 drv: $STAGE2_DRV"
python3 scripts/seed-stage2-fods.py \
  --store "$STORE_URI" \
  --store-dir "$STORE_DIR" \
  --drv "$STAGE2_DRV" \
  --nixpkgs "$NIXPKGS_PATH" \
  --scope all

echo "Disk space after Stage-2 source seeding:"
show_disk_usage

BUILD_LOG="$OUT_DIR/$ARCH/build.log"
set +e
"$NIX_BUILD_BIN" --store "$STORE_URI" \
  "${NIX_BUILD_OPTS[@]}" \
  "$STAGE2_DRV" \
  -o "$OUT_DIR/$ARCH/installer" 2>&1 | tee "$BUILD_LOG"
BUILD_RC="${PIPESTATUS[0]}"
set -e

if [ "$BUILD_RC" -ne 0 ]; then
  FAILURE_EXCERPT="$(
    grep -n -B 2 -A 35 "Reason: builder failed" "$BUILD_LOG" | tail -n 120 || true
  )"
  if [ -z "$FAILURE_EXCERPT" ]; then
    FAILURE_EXCERPT="$(tail -n 120 "$BUILD_LOG")"
  fi

  echo ""
  echo "================ ROOT-CAUSE BUILDER FAILURES ================"
  printf '%s\n' "$FAILURE_EXCERPT"
  echo "============================================================="
  show_disk_usage || true

  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "## Stage-2 build failed (\`$ARCH\`)"
      echo ""
      echo '````text'
      printf '%s\n' "$FAILURE_EXCERPT"
      echo '````'
    } >> "$GITHUB_STEP_SUMMARY"
  fi

  exit "$BUILD_RC"
fi

TARBALL="$(find -L "$OUT_DIR/$ARCH/installer" -maxdepth 1 -name 'nix-termux-*.tar.gz' -type f | head -n 1)"
if [ -n "$TARBALL" ]; then
  cp -f "$TARBALL" "$OUT_DIR/nix-termux-${ARCH}.tar.gz"
  echo "Pure Stage-2 tarball ready: $OUT_DIR/nix-termux-${ARCH}.tar.gz"
fi
