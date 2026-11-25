#!/usr/bin/env bash
# Ad-hoc sign Mach-O files in a prefixed Nix store.
#
# Run this before loading the Nix registration database: signing changes file
# contents and therefore the NAR hashes represented by the payload.

set -euo pipefail

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  echo "Usage: sign-store.sh STORE_DIR"
  exit 0
fi

if [ "$#" -ne 1 ]; then
  echo "Usage: sign-store.sh STORE_DIR" >&2
  exit 2
fi

STORE_DIR="$1"
[ -d "$STORE_DIR" ] || {
  echo "Error: store directory not found: $STORE_DIR" >&2
  exit 1
}

if command -v ldid >/dev/null 2>&1; then
  SIGNER=(ldid -S)
elif command -v codesign >/dev/null 2>&1; then
  SIGNER=(codesign --force --sign -)
else
  echo "Error: neither ldid nor codesign is available" >&2
  exit 1
fi

is_macho() {
  if command -v file >/dev/null 2>&1; then
    file -b "$1" 2>/dev/null | grep -q 'Mach-O'
    return
  fi

  magic="$(od -An -N4 -tx1 "$1" 2>/dev/null | tr -d ' \n')"
  case "$magic" in
    cffaedfe|cefaedfe|cafebabe|bebafeca|bfbafeca|cafebabf)
      return 0
      ;;
  esac
  return 1
}

signed=0
failed=0

while IFS= read -r -d '' file; do
  is_macho "$file" || continue
  if "${SIGNER[@]}" "$file" >/dev/null 2>&1; then
    signed=$((signed + 1))
  else
    echo "Error: failed to sign $file" >&2
    failed=$((failed + 1))
  fi
done < <(find "$STORE_DIR" -type f -print0)

echo "Signed $signed Mach-O files"
[ "$failed" -eq 0 ] || exit 1
