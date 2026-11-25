# Nix for rootless jailbroken iOS

Prefixed Nix store work for rootless jailbreaks (Dopamine / Procursus-style). The target layout is `/var/jb/nix`, with iOS Mach-O binaries rather than macOS binaries.

**Status:** installer and CI infrastructure are implemented; the native Nix closure is still blocked. The device installer now validates and transactionally installs device-ready payloads, but the pinned nixpkgs `pkgsCross.iphone64` stdenv cannot currently evaluate ordinary cross packages, including `hello`. The existing `bootstrap.nix` host-closure path is kept only as bootstrap research and must not be distributed as an iOS build.

## Why not `/nix`?

On rootless iOS 15+, the system volume is a **Signed System Volume (SSV)** and is read-only. You cannot create `/nix` (directory or symlink) on `/`.

| Path | Writable | Runnable binaries | Verdict |
|------|----------|-------------------|---------|
| `/nix` on `/` | No (SSV) | N/A | Impossible on rootless |
| `/var/nix` | Yes | Generally no (sandbox) | Bad for a store of executables |
| `/var/jb/nix` → preboot | Yes | Yes | Correct place |

`/var/jb` is a symlink to `/private/preboot/$boot-manifest-hash$/…`. That preboot location is writable **and** allows executing non-system binaries; plain `/var` often does not. Bind mounts on rootless only overlay **existing** directories and cannot invent a new `/nix` on SSV.

Do **not** bake the real preboot hash into store paths — it is device-specific. Use the stable `/var/jb/…` prefix and set `allow-symlinked-store = true`.

## Locked layout

```text
NIX_PREFIX=/var/jb/nix
NIX_STORE_DIR=/var/jb/nix/store
NIX_STATE_DIR=/var/jb/nix/var/nix
NIX_LOG_DIR=/var/jb/nix/var/log/nix
NIX_CONF_DIR=/var/jb/nix/etc/nix
```

Procursus userspace stays under `/var/jb/usr`, …; Nix sits alongside as `/var/jb/nix`.

## Platform: iOS Darwin, not macOS

- **Not** nixpkgs `aarch64-darwin` (macOS). macOS Mach-O does not run as iOS userspace.
- Target **iOS Darwin**: `iphoneos` / `aarch64-apple-ios` (nixpkgs: `pkgsCross.iphone64`).
- Procursus uses GNU triple `aarch64-apple-darwin` with `PLATFORM=iphoneos` and `MEMO_PREFIX=/var/jb` for `iphoneos-arm64-rootless` — same naming confusion; the SDK/min-OS is what matters.
- Bootstrap **host**: Apple Silicon Mac (`aarch64-darwin`), cross toward iOS.

## Termux vs Rootless iOS

| | Termux | Rootless iOS |
|---|--------|----------------|
| Prefix | `/data/data/com.termux/files/nix` | `/var/jb/nix` |
| Binary format | ELF (Android Bionic) | Mach-O (iOS Darwin) |
| Bootstrap method | Pure dramforever Stage 1 → Stage 2 | Stage 2 blocked by incomplete iPhone cross stdenv |
| Extra | Single fixed `armv8.2-a` ISA | Ad-hoc codesign + entitlements on device |

Nix must be built with Meson `nix-store` (`store-dir`, `localstatedir`, `log-dir`, `sysconfdir`) and `nix` (`localstatedir`, `sysconfdir`) pointed at `/var/jb/nix`. A device-ready Stage-2 closure must contain only `arm64` Mach-O files whose load commands target iOS, and it must use `/var/jb/nix/store` in its registration database.

## Files

- [`bootstrap.nix`](bootstrap.nix) — experimental host Stage-1 driver and blocked Stage-2 packaging path
- [`ios-nix-env.sh`](ios-nix-env.sh) — shell env for the device
- [`install-nix-ios.sh`](install-nix-ios.sh) — device-side archive/payload entry point
- [`install-payload.sh`](install-payload.sh) — transactional payload installer with rollback
- [`sign-store.sh`](sign-store.sh) — ad-hoc Mach-O signing helper
- [`validate-payload.sh`](validate-payload.sh) — host-side iOS Mach-O and registration validator
- [`ci-check.sh`](ci-check.sh) — Apple Silicon/Xcode/iPhoneOS SDK preflight
- [`toolkit.nix`](toolkit.nix) — packages the installer-only toolkit without a Nix closure
- [`nix.conf.template`](nix.conf.template) — includes `allow-symlinked-store`
- [`non-jailbroken-research.md`](non-jailbroken-research.md) — literature research on **native-code** near-native execution on non-jailbroken iOS sideloading (`LiveContainer`, `StikDebug`, `UTM`, `TrollStore`)

## Build the installer toolkit

The toolkit contains the installer, validator, signing helper, environment script, and configuration template. It deliberately contains no Nix closure.

```bash
nix build .#ios-toolkit
tar -tzf result/nix-ios-toolkit.tar.gz
```

The `iOS Jailbreak Bootstrap` workflow runs on every relevant pull request:

- Packages and shellchecks the installer toolkit on Ubuntu.
- Confirms the macOS runner is Apple Silicon with an iPhoneOS SDK installed.
- Compiles and ad-hoc signs an `arm64-apple-ios15.0` probe.
- Rejects malformed archives, `/nix/store` registrations, ELF payloads, non-iOS Mach-O files, and unsigned release payloads.

## Validate a device payload

Run this on the macOS build host before distributing an archive:

```bash
./ios/validate-payload.sh \
  --require-signature \
  nix-ios-jb-aarch64.tar.gz
```

The archive layout is:

```text
tarball/
  install.sh
  install-payload.sh
  sign-store.sh
  store/
  registration
```

The validator requires `store/*/bin/nix-store`, `/var/jb/nix/store` paths in `registration`, and at least one iOS Mach-O file. It rejects host macOS binaries and ELF closures.

The current `ios/bootstrap.nix -A installer` path does not produce a valid payload and is intentionally not used by CI. It builds a host closure with prefixed paths as an experiment and then runs `validate-payload.sh`; the build is expected to fail until the closure is replaced with genuine iOS Mach-O packages.

## Install (on device)

Requires a rootless jailbreak with `/var/jb` present (SSH / NewTerm).

```bash
# Install a validated payload and verify its checksum first:
NIX_IOS_SHA256=<sha256> \
  ./ios/install-nix-ios.sh --archive ./nix-ios-jb-aarch64.tar.gz

# Or, when the current payload still needs ad-hoc signing (experimental):
./ios/install-nix-ios.sh --archive ./payload.tar.gz --sign-store

# Create only the directory/config skeleton (does not install Nix):
./ios/install-nix-ios.sh --bootstrap-only

source /var/jb/nix/etc/nix/ios-nix-env.sh
```

The installer refuses legacy archives that do not include `install-payload.sh`. Before replacing an existing prefix it moves it aside as `/var/jb/nix.backup-<timestamp>`. If installation or database registration fails, it restores the previous prefix.

`--sign-store` changes file contents. The shared installer signs before loading the database, but the supplied registration hashes still describe the unsigned closure. Prefer signing on the macOS build host; on-device signing is an experimental fallback and can make `nix store verify` report mismatches.

## Limitations

- No official binary cache (custom store prefix).
- The pinned nixpkgs iPhone cross stdenv fails while evaluating the Apple SDK propagation, so no native Nix closure is produced yet.
- A real closure still needs iOS-appropriate dependencies, linking, ad-hoc signing, and registration after signing.
- The macOS host Stage-1 driver is useful for bootstrap experiments but is not itself runnable on iOS.
- RootHide (randomized jb root) is out of scope; this track assumes fixed `/var/jb`.
