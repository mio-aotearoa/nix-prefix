#!/usr/bin/env bash
# Validate a built rootless-iOS installer archive before it is installed.
#
# This command is intended for the macOS build host. It checks archive paths,
# the prefixed registration database, and Mach-O platform metadata.

set -euo pipefail

ARCHIVE=""
REQUIRE_IOS=1
REQUIRE_SIGNATURE=0

usage() {
  cat <<EOF
Usage: validate-payload.sh ARCHIVE [options]

Options:
  --allow-foreign-macho  Skip the iOS platform check (unsafe; for diagnostics)
  --require-signature    Require every Mach-O file to have a valid signature
  --help                 Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --allow-foreign-macho)
      REQUIRE_IOS=0
      shift
      ;;
    --require-signature)
      REQUIRE_SIGNATURE=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    -*)
      echo "Error: unknown option: $1" >&2
      exit 2
      ;;
    *)
      [ -z "$ARCHIVE" ] || {
        echo "Error: duplicate archive argument: $1" >&2
        exit 2
      }
      ARCHIVE="$1"
      shift
      ;;
  esac
done

[ -n "$ARCHIVE" ] || {
  usage >&2
  exit 2
}
[ -f "$ARCHIVE" ] || {
  echo "Error: archive not found: $ARCHIVE" >&2
  exit 1
}

for tool in tar file otool; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "Error: required tool not found: $tool" >&2
    exit 1
  }
done

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nix-ios-validate.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

is_ios_macho() {
  otool -l "$1" 2>/dev/null | awk '
    /cmd LC_VERSION_MIN_IPHONEOS/ { found = 1 }
    /cmd LC_BUILD_VERSION/ { build = 1 }
    build && /platform [0-9]+/ {
      if ($2 == 2) found = 1
      build = 0
    }
    END { exit found ? 0 : 1 }
  '
}

is_signed_macho() {
  if command -v codesign >/dev/null 2>&1 && codesign --verify "$1" >/dev/null 2>&1; then
    return 0
  fi
  if command -v ldid >/dev/null 2>&1 && ldid -V "$1" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

echo "==> Checking archive paths"
tar -tzf "$ARCHIVE" > "$WORK_DIR/entries"
if grep -Eq '^/|(^|/)\.\.(/|$)' "$WORK_DIR/entries"; then
  echo "Error: archive contains an absolute or parent-traversing path" >&2
  exit 1
fi

echo "==> Extracting payload"
tar -xzf "$ARCHIVE" -C "$WORK_DIR"

PAYLOAD_DIR="$WORK_DIR/tarball"
if [ ! -d "$PAYLOAD_DIR" ]; then
  PAYLOAD_DIR="$WORK_DIR"
fi

for required in install.sh store registration; do
  [ -e "$PAYLOAD_DIR/$required" ] || {
    echo "Error: payload is missing $required" >&2
    exit 1
  }
done

if grep -Eq '(^|[[:space:]])/nix/store/' "$PAYLOAD_DIR/registration"; then
  echo "Error: registration contains /nix/store paths" >&2
  exit 1
fi
registered_count=0
missing_count=0
while read -r registered_path _; do
  [ -n "$registered_path" ] || continue
  case "$registered_path" in
    /var/jb/nix/store/*)
      registered_count=$((registered_count + 1))
      store_entry="${registered_path#/var/jb/nix/store/}"
      store_entry="${store_entry%%/*}"
      if [ ! -d "$PAYLOAD_DIR/store/$store_entry" ]; then
        echo "Error: registered store path is missing from payload: $registered_path" >&2
        missing_count=$((missing_count + 1))
      fi
      ;;
    *)
      echo "Error: registration contains a foreign store path: $registered_path" >&2
      exit 1
      ;;
  esac
done < "$PAYLOAD_DIR/registration"

[ "$registered_count" -gt 0 ] || {
  echo "Error: registration has no /var/jb/nix/store paths" >&2
  exit 1
}
[ "$missing_count" -eq 0 ] || {
  echo "Error: registration references $missing_count missing store paths" >&2
  exit 1
}

echo "==> Checking closure contents"
if find "$PAYLOAD_DIR/store" -type f -exec file {} + 2>/dev/null | grep -q 'ELF'; then
  echo "Error: closure contains ELF binaries" >&2
  exit 1
fi

macho_count=0
ios_count=0
foreign=0
unsigned=0

while IFS= read -r -d '' entry; do
  description="$(file -b "$entry" 2>/dev/null || true)"
  case "$description" in
    *Mach-O*) ;;
    *) continue ;;
  esac

  macho_count=$((macho_count + 1))

  if [ "$REQUIRE_IOS" -eq 1 ]; then
    if is_ios_macho "$entry"; then
      ios_count=$((ios_count + 1))
    else
      echo "Error: non-iOS Mach-O: ${entry#"$PAYLOAD_DIR/"}" >&2
      foreign=$((foreign + 1))
    fi
  fi

  if [ "$REQUIRE_SIGNATURE" -eq 1 ]; then
    if ! is_signed_macho "$entry"; then
      echo "Error: unsigned Mach-O: ${entry#"$PAYLOAD_DIR/"}" >&2
      unsigned=$((unsigned + 1))
    fi
  fi
done < <(find "$PAYLOAD_DIR/store" -type f -print0)

[ "$macho_count" -gt 0 ] || {
  echo "Error: closure contains no Mach-O files" >&2
  exit 1
}
[ "$foreign" -eq 0 ] || {
  echo "Error: closure contains $foreign non-iOS Mach-O files" >&2
  exit 1
}
[ "$unsigned" -eq 0 ] || {
  echo "Error: closure contains $unsigned unsigned Mach-O files" >&2
  exit 1
}

nix_store_count=0
while IFS= read -r -d '' nix_store; do
  nix_store_count=$((nix_store_count + 1))
  description="$(file -b "$nix_store" 2>/dev/null || true)"
  case "$description" in
    *Mach-O*) ;;
    *)
      echo "Error: bin/nix-store is not Mach-O: ${nix_store#"$PAYLOAD_DIR/"}" >&2
      exit 1
      ;;
  esac
  if [ "$REQUIRE_IOS" -eq 1 ] && ! is_ios_macho "$nix_store"; then
    echo "Error: bin/nix-store does not target iOS: ${nix_store#"$PAYLOAD_DIR/"}" >&2
    exit 1
  fi
  if [ "$REQUIRE_SIGNATURE" -eq 1 ] && ! is_signed_macho "$nix_store"; then
    echo "Error: bin/nix-store is unsigned: ${nix_store#"$PAYLOAD_DIR/"}" >&2
    exit 1
  fi
done < <(find "$PAYLOAD_DIR/store" -path '*/bin/nix-store' \( -type f -o -type l \) -print0)

[ "$nix_store_count" -gt 0 ] || {
  echo "Error: closure is missing bin/nix-store" >&2
  exit 1
}

echo "==> Payload valid"
printf 'Mach-O files: %d\n' "$macho_count"
[ "$REQUIRE_IOS" -eq 1 ] && printf 'iOS Mach-O files: %d\n' "$ios_count"
printf 'Registration entries: %d\n' "$(wc -l < "$PAYLOAD_DIR/registration" | tr -d ' ')"
