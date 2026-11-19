# Nix for rootless jailbroken iOS

Prefixed Nix store for rootless jailbreaks (Dopamine / Procursus-style). Parallel track to the Termux (`aarch64-linux`) bootstrap in the repo root.

**Status:** scaffolding / incomplete. First goal is a tarball + installer that places Nix under `/var/jb/nix` with Mach-O path rewrite.

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
NIX_STATE_DIR=/var/jb/nix/var
NIX_CONF_DIR=/var/jb/nix/etc
```

Procursus userspace stays under `/var/jb/usr`, …; Nix sits alongside as `/var/jb/nix`.

## Platform: iOS Darwin, not macOS

- **Not** nixpkgs `aarch64-darwin` (macOS). macOS Mach-O does not run as iOS userspace.
- Target **iOS Darwin**: `iphoneos` / `aarch64-apple-ios` (nixpkgs: `pkgsCross.iphone64`).
- Procursus uses GNU triple `aarch64-apple-darwin` with `PLATFORM=iphoneos` and `MEMO_PREFIX=/var/jb` for `iphoneos-arm64-rootless` — same naming confusion; the SDK/min-OS is what matters.
- Bootstrap **host**: Apple Silicon Mac (`aarch64-darwin`), cross toward iOS.

## Fixup vs Termux

| | Termux | Rootless iOS |
|---|--------|----------------|
| Prefix | `/data/data/com.termux/files/nix` | `/var/jb/nix` |
| Binary format | ELF | Mach-O |
| Path rewrite | `patchelf` | `install_name_tool` |
| Extra | — | Ad-hoc codesign + entitlements on device |

Nix itself is built with Meson `libstore:store-dir` / `localstatedir` / `sysconfdir` pointed at the `/var/jb/nix` paths. Other closure paths are rewritten from `/nix/store` → `/var/jb/nix/store`.

## Files

- [`bootstrap.nix`](bootstrap.nix) — build installer tarball (host: `aarch64-darwin`)
- [`ios-nix-env.sh`](ios-nix-env.sh) — shell env for the device
- [`install-nix-ios.sh`](install-nix-ios.sh) — device-side installer skeleton
- [`nix.conf.template`](nix.conf.template) — includes `allow-symlinked-store`

## Build (on Mac)

```bash
# From repo root, on aarch64-darwin:
nix-build ios/bootstrap.nix -A installer
```

## Install (on device)

Requires a rootless jailbreak with `/var/jb` present (SSH / NewTerm).

```bash
# After extracting a release tarball, or from a checked-out tree:
./ios/install-nix-ios.sh
source /var/jb/nix/etc/ios-nix-env.sh   # or copy ios-nix-env.sh into place
```

## Limitations

- No official binary cache (custom store prefix).
- Full stdenv / large closure is deferred; first milestone is Nix + a tiny closure.
- Binaries need iOS-appropriate linking and codesigning; macOS-only builds will not run on device.
- RootHide (randomized jb root) is out of scope; this track assumes fixed `/var/jb`.
