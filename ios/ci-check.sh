#!/usr/bin/env bash
# Validate the iOS build-host assumptions and produce a real iOS Mach-O probe.

set -euo pipefail

ROOT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"

die() {
  echo "Error: $*" >&2
  exit 1
}

[ "$(uname -s)" = "Darwin" ] || die "an iOS build host must be macOS"
[ "$(uname -m)" = "arm64" ] || die "an Apple Silicon macOS host is required"

command -v xcrun >/dev/null 2>&1 || die "xcrun is unavailable"
command -v xcodebuild >/dev/null 2>&1 || die "xcodebuild is unavailable"

SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version)"
[ -d "$SDK_PATH" ] || die "iPhoneOS SDK not found"

echo "==> Build host"
printf 'macOS: %s\n' "$(sw_vers -productVersion)"
printf 'Xcode: %s\n' "$(xcodebuild -version | paste -sd ' ' -)"
printf 'iPhoneOS SDK: %s (%s)\n' "$SDK_VERSION" "$SDK_PATH"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nix-ios-ci.XXXXXX")"
FAKE_PREFIX="$WORK_DIR/jb"
ARTIFACT_DIR="${NIX_IOS_ARTIFACT_DIR:-}"
mkdir -p "$FAKE_PREFIX"
if [ -n "$ARTIFACT_DIR" ]; then
  mkdir -p "$ARTIFACT_DIR"
fi
trap 'rm -rf "$WORK_DIR"' EXIT

cat > "$WORK_DIR/probe.c" <<'EOF'
#include <stdio.h>
#include <sys/utsname.h>

int main(void) {
  struct utsname info;
  if (uname(&info) != 0) {
    return 1;
  }
  printf("NIX_IOS_CROSS_OK arch=%s machine=%s\n", "arm64", info.machine);
  return 0;
}
EOF

echo "==> Compiling iOS cross probe"
xcrun --sdk iphoneos clang \
  -target arm64-apple-ios15.0 \
  -miphoneos-version-min=15.0 \
  -O2 \
  "$WORK_DIR/probe.c" \
  -o "$WORK_DIR/probe"

file "$WORK_DIR/probe" | grep -q 'Mach-O 64-bit executable arm64' \
  || die "probe is not an arm64 Mach-O executable"
otool -l "$WORK_DIR/probe" | awk '
  /cmd LC_VERSION_MIN_IPHONEOS/ { found = 1 }
  /cmd LC_BUILD_VERSION/ { build = 1 }
  build && /platform [0-9]+/ {
    if ($2 == 2) found = 1
    build = 0
  }
  END { exit found ? 0 : 1 }
' || die "probe does not target iOS"
codesign --force --sign - "$WORK_DIR/probe" >/dev/null
codesign --verify "$WORK_DIR/probe"
echo "Generated a signed arm64 iOS Mach-O probe"

PAYLOAD_ROOT="$WORK_DIR/payload/tarball"
PAYLOAD_STORE="$PAYLOAD_ROOT/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-ios-probe"
mkdir -p "$PAYLOAD_STORE/bin"
cp "$WORK_DIR/probe" "$PAYLOAD_STORE/bin/nix"
ln -s nix "$PAYLOAD_STORE/bin/nix-store"
printf '%s\n' '/var/jb/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-ios-probe/bin/nix' \
  > "$PAYLOAD_ROOT/registration"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$PAYLOAD_ROOT/install.sh"
chmod +x "$PAYLOAD_ROOT/install.sh"
tar -czf "$WORK_DIR/synthetic-payload.tar.gz" -C "$WORK_DIR/payload" tarball

if [ -n "$ARTIFACT_DIR" ]; then
  cp "$WORK_DIR/probe" "$ARTIFACT_DIR/ios-probe"
  file "$ARTIFACT_DIR/ios-probe" > "$ARTIFACT_DIR/ios-probe.txt"
  otool -l "$ARTIFACT_DIR/ios-probe" >> "$ARTIFACT_DIR/ios-probe.txt"
fi

echo "==> Checking shell entry points"
for script in "$ROOT_DIR"/ios/*.sh; do
  bash -n "$script"
done
"$ROOT_DIR/ios/install-nix-ios.sh" --help >/dev/null
"$ROOT_DIR/ios/install-payload.sh" --help >/dev/null
"$ROOT_DIR/ios/validate-payload.sh" --help >/dev/null
"$ROOT_DIR/ios/sign-store.sh" --help >/dev/null

echo "==> Testing payload validator"
"$ROOT_DIR/ios/validate-payload.sh" \
  "$WORK_DIR/synthetic-payload.tar.gz" \
  --require-signature >/dev/null

FOREIGN_ROOT="$WORK_DIR/foreign-payload/tarball"
FOREIGN_STORE="$FOREIGN_ROOT/store/cccccccccccccccccccccccccccccccc-macos-probe"
mkdir -p "$FOREIGN_STORE/bin"
cp /usr/bin/true "$FOREIGN_STORE/bin/nix-store"
printf '%s\n' '/var/jb/nix/store/cccccccccccccccccccccccccccccccc-macos-probe/bin/nix-store' \
  > "$FOREIGN_ROOT/registration"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$FOREIGN_ROOT/install.sh"
chmod +x "$FOREIGN_ROOT/install.sh"
tar -czf "$WORK_DIR/foreign-payload.tar.gz" -C "$WORK_DIR/foreign-payload" tarball
if "$ROOT_DIR/ios/validate-payload.sh" \
  "$WORK_DIR/foreign-payload.tar.gz" >/dev/null 2>&1; then
  die "validator accepted a macOS Mach-O payload"
fi

SCRIPT_STORE_ROOT="$WORK_DIR/script-payload/tarball"
SCRIPT_STORE="$SCRIPT_STORE_ROOT/store/dddddddddddddddddddddddddddddddd-ios-wrapper"
mkdir -p "$SCRIPT_STORE/bin" "$SCRIPT_STORE/share"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$SCRIPT_STORE/bin/nix-store"
cp "$WORK_DIR/probe" "$SCRIPT_STORE/share/probe"
printf '%s\n' '/var/jb/nix/store/dddddddddddddddddddddddddddddddd-ios-wrapper/bin/nix-store' \
  > "$SCRIPT_STORE_ROOT/registration"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$SCRIPT_STORE_ROOT/install.sh"
chmod +x "$SCRIPT_STORE/bin/nix-store" "$SCRIPT_STORE_ROOT/install.sh"
tar -czf "$WORK_DIR/script-payload.tar.gz" -C "$WORK_DIR/script-payload" tarball
if "$ROOT_DIR/ios/validate-payload.sh" \
  "$WORK_DIR/script-payload.tar.gz" >/dev/null 2>&1; then
  die "validator accepted a non-Mach-O bin/nix-store"
fi

echo "==> Testing bootstrap-only layout"
NIX_IOS_JB_PREFIX="$FAKE_PREFIX" \
  "$ROOT_DIR/ios/install-nix-ios.sh" --bootstrap-only >/dev/null
[ -f "$FAKE_PREFIX/nix/etc/nix/nix.conf" ] \
  || die "bootstrap-only install did not write nix.conf"
[ -f "$FAKE_PREFIX/nix/etc/nix/ios-nix-env.sh" ] \
  || die "bootstrap-only install did not write ios-nix-env.sh"
grep -Fq 'allow-symlinked-store = true' "$FAKE_PREFIX/nix/etc/nix/nix.conf" \
  || die "bootstrap-only install did not enable allow-symlinked-store"

TEST_PAYLOAD_DIR="$WORK_DIR/install-payload"
TEST_STORE="$TEST_PAYLOAD_DIR/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-ios-installer-test"
mkdir -p "$TEST_STORE/bin"
cat > "$TEST_STORE/bin/nix-store" <<'EOF'
#!/bin/sh
cat >/dev/null
EOF
cat > "$TEST_STORE/bin/nix" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$TEST_STORE/bin/nix-store" "$TEST_STORE/bin/nix"
cp "$ROOT_DIR/ios/ios-nix-env.sh" "$TEST_PAYLOAD_DIR/ios-nix-env.sh"
printf '%s\n' "$FAKE_PREFIX/nix/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-ios-installer-test/bin/nix" \
  > "$TEST_PAYLOAD_DIR/registration"
NIX_IOS_JB_PREFIX="$FAKE_PREFIX" \
  "$ROOT_DIR/ios/install-nix-ios.sh" \
  --payload-dir "$TEST_PAYLOAD_DIR" >/dev/null
test -L "$FAKE_PREFIX/nix/var/nix/profiles/default" \
  || die "payload install did not create the default profile"

cat > "$TEST_STORE/bin/nix-store" <<'EOF'
#!/bin/sh
exit 1
EOF
if NIX_IOS_JB_PREFIX="$FAKE_PREFIX" \
  "$ROOT_DIR/ios/install-nix-ios.sh" \
  --payload-dir "$TEST_PAYLOAD_DIR" >/dev/null 2>&1; then
  die "installer unexpectedly accepted a failing nix-store registration"
fi
test -f "$FAKE_PREFIX/nix/etc/nix/nix.conf" \
  || die "rollback did not restore the previous prefix"

echo "==> Checking locked paths"
grep -Fq 'NIX_PREFIX="/var/jb/nix"' "$ROOT_DIR/ios/ios-nix-env.sh" \
  || die "ios-nix-env.sh does not lock /var/jb/nix"
grep -Fq 'allow-symlinked-store = true' "$ROOT_DIR/ios/nix.conf.template" \
  || die "nix.conf.template does not enable allow-symlinked-store"

echo "iOS build-host preflight passed"
