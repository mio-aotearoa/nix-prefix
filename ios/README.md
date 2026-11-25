# Nix for rootless jailbroken iOS

Prefixed Nix store for rootless jailbreaks (Dopamine / Procursus-style), following [dramforever's pure Stage 1 → Stage 2 bootstrap](https://dram.page/p/bootstrapping-nix/) with zero path-replacing hacks. Parallel track to the Termux (`aarch64-unknown-linux-android` Bionic) bootstrap in the repo root.

**Status:** scaffolding / incomplete. First goal is a pure Stage-2 tarball + installer placing Nix under `/var/jb/nix`.

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
| Bootstrap method | Pure dramforever Stage 1 → Stage 2 | Pure dramforever Stage 1 → Stage 2 |
| Extra | Single fixed `armv8.2-a` ISA | Ad-hoc codesign + entitlements on device |

Nix itself is built with Meson `nix-store` (`store-dir`, `localstatedir`, `log-dir`, `sysconfdir`) and `nix` (`localstatedir`, `sysconfdir`) pointed at `/var/jb/nix`. Stage 2 builds the entire closure natively under `/var/jb/nix/store` without any binary path rewriting.

## Files

- [`bootstrap.nix`](bootstrap.nix) — pure Stage 1 (`nixStage1`) and Stage 2 (`installer`) derivations (host: `aarch64-darwin`)
- [`ios-nix-env.sh`](ios-nix-env.sh) — shell env for the device
- [`install-nix-ios.sh`](install-nix-ios.sh) — device-side installer skeleton
- [`nix.conf.template`](nix.conf.template) — includes `allow-symlinked-store`
- [`non-jailbroken-research.md`](non-jailbroken-research.md) — literature research on **native-code** near-native execution on non-jailbroken iOS sideloading (`LiveContainer`, `StikDebug`, `UTM`, `TrollStore`)

## Build (on Mac)

```bash
# Stage 1 (host Nix): build Stage-1 Nix driver targeting /var/jb/nix/store
nix-build ios/bootstrap.nix -A nixStage1

# Stage 2 (pure dramforever bootstrap): build closure natively for /var/jb/nix/store
nix-build --store 'local?root=/tmp/ios-stage2&store=/var/jb/nix/store' ios/bootstrap.nix -A installer
```

## Install (on device)

Requires a rootless jailbreak with `/var/jb` present (SSH / NewTerm).

```bash
# After extracting a release tarball, or from a checked-out tree:
./ios/install-nix-ios.sh
source /var/jb/nix/etc/nix/ios-nix-env.sh
```

## Limitations

- No official binary cache (custom store prefix).
- Full stdenv / large closure is deferred; first milestone is Nix + a tiny closure.
- Binaries need iOS-appropriate linking and codesigning; macOS-only builds will not run on device.
- RootHide (randomized jb root) is out of scope; this track assumes fixed `/var/jb`.
