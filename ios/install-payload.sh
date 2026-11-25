#!/usr/bin/env bash
# Install an already-built rootless iOS Nix payload.
#
# Expected payload files:
#   store/               Prefixed Nix closure
#   registration         Nix registration database for /var/jb/nix/store
#   ios-nix-env.sh       Optional device environment script

set -euo pipefail

JB_PREFIX="${NIX_IOS_JB_PREFIX:-/var/jb}"
NIX_PREFIX="${JB_PREFIX}/nix"
STORE_DIR="${NIX_PREFIX}/store"
STATE_DIR="${NIX_PREFIX}/var/nix"
LOG_DIR="${NIX_PREFIX}/var/log/nix"
CONF_DIR="${NIX_PREFIX}/etc/nix"

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
Usage: install-payload.sh --payload-dir DIR [options]

Options:
  --bootstrap-only  Create the directory/config skeleton without a Nix closure.
  --sign-store      Ad-hoc sign Mach-O files before loading the Nix database.
  --help            Show this help.

Environment:
  NIX_IOS_SIGN=1          Same as --sign-store.
  NIX_IOS_JB_PREFIX=PATH  Override /var/jb (intended for testing only).
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
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

[ "$(uname -s)" = "Darwin" ] || die "this installer must run on iOS/Darwin"
case "$(uname -m)" in
  arm64|aarch64) ;;
  *) die "aarch64/arm64 only (detected: $(uname -m))" ;;
esac

[ -d "$JB_PREFIX" ] || [ -L "$JB_PREFIX" ] \
  || die "$JB_PREFIX not found. Activate a rootless jailbreak first."

case "$NIX_PREFIX" in
  /|/var|/var/jb|/private|/private/preboot)
    die "refusing unsafe Nix prefix: $NIX_PREFIX"
    ;;
esac

if [ "$BOOTSTRAP_ONLY" -eq 0 ]; then
  [ -n "$PAYLOAD_DIR" ] || die "--payload-dir is required without --bootstrap-only"
  [ -d "$PAYLOAD_DIR" ] || die "payload directory not found: $PAYLOAD_DIR"
  [ -d "$PAYLOAD_DIR/store" ] || die "payload is missing store/"
  [ -f "$PAYLOAD_DIR/registration" ] || die "payload is missing registration"

  if grep -Eq '(^|[[:space:]])/nix/store/' "$PAYLOAD_DIR/registration"; then
    die "registration contains a /nix/store path; expected /var/jb/nix/store"
  fi
  grep -Fq "$STORE_DIR/" "$PAYLOAD_DIR/registration" \
    || die "registration does not contain $STORE_DIR paths"

  find "$PAYLOAD_DIR/store" -mindepth 1 -maxdepth 1 -print -quit | grep -q . \
    || die "payload store directory is empty"
fi

info "Checking rootless prefix"
success "Rootless prefix OK ($JB_PREFIX), arch=$(uname -m)"

STAMP="$(date +%Y%m%d-%H%M%S)-$$"
BACKUP_PREFIX="${NIX_PREFIX}.backup-${STAMP}"
FAILED_PREFIX="${NIX_PREFIX}.failed-${STAMP}"
INSTALL_OK=0

rollback() {
  status=$?
  trap - EXIT
  if [ "$INSTALL_OK" -eq 0 ]; then
    warning "installation failed; restoring the previous prefix"
    if [ -e "$NIX_PREFIX" ] || [ -L "$NIX_PREFIX" ]; then
      mv "$NIX_PREFIX" "$FAILED_PREFIX" 2>/dev/null || true
    fi
    if [ -e "$BACKUP_PREFIX" ] || [ -L "$BACKUP_PREFIX" ]; then
      mv "$BACKUP_PREFIX" "$NIX_PREFIX"
      warning "previous prefix restored"
    fi
  fi
  exit "$status"
}
trap rollback EXIT

if [ -e "$NIX_PREFIX" ] || [ -L "$NIX_PREFIX" ]; then
  info "Preserving existing prefix at $BACKUP_PREFIX"
  mv "$NIX_PREFIX" "$BACKUP_PREFIX"
fi

mkdir -p "$STORE_DIR"
mkdir -p "$STATE_DIR/db" "$STATE_DIR/gcroots" "$STATE_DIR/temproots"
mkdir -p "$STATE_DIR/profiles/per-user/${USER:-mobile}"
mkdir -p "$LOG_DIR/drvs"
mkdir -p "$CONF_DIR"

if [ "$BOOTSTRAP_ONLY" -eq 1 ]; then
  info "Creating bootstrap-only layout"
else
  info "Copying Nix closure"
  cp -a "$PAYLOAD_DIR/store/." "$STORE_DIR/"
fi

if [ "$SIGN_STORE" -eq 1 ] && [ "$BOOTSTRAP_ONLY" -eq 0 ]; then
  SIGNER="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/sign-store.sh"
  [ -x "$SIGNER" ] || die "sign-store.sh is missing or not executable"
  info "Applying ad-hoc signatures before database registration"
  "$SIGNER" "$STORE_DIR"
fi

if [ "$BOOTSTRAP_ONLY" -eq 0 ]; then
  info "Initializing Nix database"
  NIX_STORE_BIN=""
  while IFS= read -r -d '' candidate; do
    NIX_STORE_BIN="$candidate"
    break
  done < <(find "$STORE_DIR" -path '*/bin/nix-store' -type f -print0)
  [ -n "$NIX_STORE_BIN" ] || die "payload does not contain bin/nix-store"

  export NIX_STORE_DIR="$STORE_DIR"
  export NIX_STATE_DIR="$STATE_DIR"
  export NIX_LOG_DIR="$LOG_DIR"
  export NIX_CONF_DIR="$CONF_DIR"
  "$NIX_STORE_BIN" --load-db < "$PAYLOAD_DIR/registration"

  NIX_BIN=""
  while IFS= read -r -d '' candidate; do
    NIX_BIN="$candidate"
    break
  done < <(find "$STORE_DIR" -path '*/bin/nix' -type f -print0)
  if [ -n "$NIX_BIN" ]; then
    NIX_PACKAGE="$(dirname "$(dirname "$NIX_BIN")")"
    ln -sfn "$NIX_PACKAGE" "$STATE_DIR/profiles/default"
  fi
fi

info "Writing Nix configuration"
cat > "$CONF_DIR/nix.conf" <<EOF
# Nix configuration for rootless jailbroken iOS
build-users-group =
sandbox = false
allow-symlinked-store = true
experimental-features = nix-command flakes
max-jobs = auto
cores = 0
substituters =
trusted-public-keys =
keep-build-log = true
auto-optimise-store = false
EOF

ENV_SOURCE="${PAYLOAD_DIR}/ios-nix-env.sh"
if [ "$BOOTSTRAP_ONLY" -eq 1 ]; then
  ENV_SOURCE="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)/ios-nix-env.sh"
fi
if [ -f "$ENV_SOURCE" ]; then
  cp "$ENV_SOURCE" "$CONF_DIR/ios-nix-env.sh"
  chmod 644 "$CONF_DIR/ios-nix-env.sh"
else
  warning "ios-nix-env.sh not found; environment script was not installed"
fi

if [ "$BOOTSTRAP_ONLY" -eq 1 ]; then
  ln -sfn "$STATE_DIR/profiles/per-user/${USER:-mobile}/profile" \
    "$STATE_DIR/profiles/default"
fi

INSTALL_OK=1
trap - EXIT

success "Nix prefix ready at $NIX_PREFIX"
if [ -e "$BACKUP_PREFIX" ] || [ -L "$BACKUP_PREFIX" ]; then
  info "Previous prefix retained at $BACKUP_PREFIX"
fi
printf '\nNext:\n  source %s/ios-nix-env.sh\n' "$CONF_DIR"
