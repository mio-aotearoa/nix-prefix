#!/usr/bin/env bash
# Device-side entry point for rootless jailbroken iOS.

set -euo pipefail

JB_PREFIX="${NIX_IOS_JB_PREFIX:-/var/jb}"
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd)"

ARCHIVE=""
PAYLOAD_DIR=""
BOOTSTRAP_ONLY=0
SIGN_STORE="${NIX_IOS_SIGN:-0}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { printf '%b==>%b %s\n' "$BLUE" "$NC" "$1"; }
success() { printf '%b==>%b %s\n' "$GREEN" "$NC" "$1"; }
warning() { printf '%bWarning:%b %s\n' "$YELLOW" "$NC" "$1" >&2; }
die() { printf '%bError:%b %s\n' "$RED" "$NC" "$1" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: install-nix-ios.sh [options]

Options:
  --archive PATH    Install from a built Nix iOS payload archive.
  --payload-dir DIR Install from an extracted payload directory.
  --bootstrap-only  Create the directory/config skeleton without Nix binaries.
  --sign-store      Ad-hoc sign Mach-O files before database registration.
  --help            Show this help.

Without --archive or --payload-dir, the installer looks for a payload beside
this checkout or in result/. It refuses to install a legacy host-only payload.

Environment:
  NIX_IOS_SHA256=HEX       Verify the archive before extraction.
  NIX_IOS_SIGN=1           Same as --sign-store.
  NIX_IOS_JB_PREFIX=PATH   Override /var/jb (intended for testing only).
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --archive)
      [ "$#" -ge 2 ] || die "--archive needs a value"
      ARCHIVE="$2"
      shift 2
      ;;
    --payload-dir)
      [ "$#" -ge 2 ] || die "--payload-dir needs a value"
      PAYLOAD_DIR="$2"
      shift 2
      ;;
    --bootstrap-only)
      BOOTSTRAP_ONLY=1
      shift
      ;;
    --sign-store)
      SIGN_STORE=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

echo ""
echo "+--------------------------------------------+"
echo "|  Nix for rootless iOS (/var/jb/nix)        |"
echo "+--------------------------------------------+"
echo ""

info "Checking environment"
[ "$(uname -s)" = "Darwin" ] || die "this installer must run on iOS/Darwin"
case "$(uname -m)" in
  arm64|aarch64) ;;
  *) die "aarch64/arm64 only (detected: $(uname -m))" ;;
esac
[ -d "$JB_PREFIX" ] || [ -L "$JB_PREFIX" ] \
  || die "$JB_PREFIX not found. Activate a rootless jailbreak first."
success "Rootless prefix OK ($JB_PREFIX), arch=$(uname -m)"

if [ "$BOOTSTRAP_ONLY" -eq 1 ]; then
  exec "$SCRIPT_DIR/install-payload.sh" --bootstrap-only
fi

if [ -z "$PAYLOAD_DIR" ] && [ -z "$ARCHIVE" ]; then
  for candidate in \
    "$SCRIPT_DIR/nix-ios-jb-aarch64.tar.gz" \
    "$SCRIPT_DIR/tarball.tar.gz" \
    "$REPO_ROOT/result/nix-ios-jb-aarch64.tar.gz" \
    "$REPO_ROOT/result/tarball.tar.gz"
  do
    if [ -f "$candidate" ]; then
      ARCHIVE="$candidate"
      break
    fi
  done
fi

if [ -z "$PAYLOAD_DIR" ] && [ -z "$ARCHIVE" ]; then
  die "no Nix iOS payload found; pass --archive or use --bootstrap-only"
fi

if [ -n "$PAYLOAD_DIR" ]; then
  [ -d "$PAYLOAD_DIR" ] || die "payload directory not found: $PAYLOAD_DIR"
else
  [ -f "$ARCHIVE" ] || die "payload archive not found: $ARCHIVE"

  if [ -n "${NIX_IOS_SHA256:-}" ]; then
    info "Verifying archive checksum"
    actual="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
    [ "$actual" = "$NIX_IOS_SHA256" ] \
      || die "archive SHA-256 mismatch: expected $NIX_IOS_SHA256, got $actual"
  fi

  info "Inspecting archive"
  entries="$(mktemp "${JB_PREFIX}/tmp.entries.XXXXXX")"
  extract_dir="$(mktemp -d "${JB_PREFIX}/tmp.nix-install.XXXXXX")"
  trap 'rm -f "$entries"; rm -rf "$extract_dir"' EXIT
  tar -tzf "$ARCHIVE" > "$entries"
  if grep -Eq '^/|(^|/)\.\.(/|$)' "$entries"; then
    die "archive contains an absolute or parent-traversing path"
  fi

  info "Extracting payload"
  tar -xzf "$ARCHIVE" -C "$extract_dir"
  if [ -f "$extract_dir/tarball/install-payload.sh" ]; then
    PAYLOAD_DIR="$extract_dir/tarball"
  elif [ -f "$extract_dir/install-payload.sh" ]; then
    PAYLOAD_DIR="$extract_dir"
  else
    die "payload lacks install-payload.sh; legacy host-only archives are unsupported"
  fi
fi

[ -x "$SCRIPT_DIR/install-payload.sh" ] \
  || die "install-payload.sh is missing or not executable"

args=(--payload-dir "$PAYLOAD_DIR")
if [ "$SIGN_STORE" -eq 1 ]; then
  args+=(--sign-store)
fi

"$SCRIPT_DIR/install-payload.sh" "${args[@]}"
