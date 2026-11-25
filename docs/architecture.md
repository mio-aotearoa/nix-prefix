# Architecture & Pure dramforever Stage 1 → Stage 2 Bootstrap

Based directly on [dramforever's *Bootstrapping Nix*](https://dram.page/p/bootstrapping-nix/), with **zero `patchelf` / path-replacing hacks**.

## Directory Layout

All Nix compile-time Meson options (`store-dir`, `localstatedir`, `log-dir`, `sysconfdir`) on both `nix-store` and `nix` (CLI) match runtime environment variables:

```text
NIX_PREFIX    = /data/data/com.termux/files/nix
NIX_STORE_DIR = /data/data/com.termux/files/nix/store
NIX_STATE_DIR = /data/data/com.termux/files/nix/var/nix       # localstatedir (/var) + /nix
NIX_LOG_DIR   = /data/data/com.termux/files/nix/var/log/nix   # log-dir
NIX_CONF_DIR  = /data/data/com.termux/files/nix/etc/nix       # sysconfdir (/etc) + /nix
TMPDIR        = /data/data/com.termux/files/usr/tmp           # Android has no global /tmp
```

> **Important:** Meson appends `/nix` to `localstatedir` and `sysconfdir`, whereas `NIX_STATE_DIR` and `NIX_CONF_DIR` expect the suffixed paths (`.../var/nix` and `.../etc/nix`). `log-dir` is absolute and not suffixed.

## Pure dramforever 3-Flavor Bootstrap (Zero Path-Replacing Hacks)

Why we **do not** use `patchelf` / text path-replacement to rewrite `/nix/store` binaries into `/data/data/com.termux/files/nix/store`:
- Store path hashes in Nix depend on `builtins.storeDir`. Rewriting `/nix/store/<old-hash>-*` into `/data/data/com.termux/files/nix/store/<old-hash>-*` produces hashes that **never match** derivations evaluated for `/data/data/com.termux/files/nix/store`, and breaks embedded `.rodata` paths inside ELF binaries.
- Instead, `bootstrap.nix` follows dramforever's exact pure multi-stage bootstrap:

1. **Flavor 0 (Normal host Nix):** lives in `/nix/store`, operates on `/nix/store`.
2. **Flavor 1 (`nixStage1` — `.#nix-stage1`):** built by host Nix, lives in `/nix/store`, configured with `store-dir = /data/data/com.termux/files/nix/store`, `localstatedir = /data/data/com.termux/files/nix/var`, `log-dir = /data/data/com.termux/files/nix/var/log/nix`, and `sysconfdir = /data/data/com.termux/files/nix/etc`. Modern Nix also supports `--store 'local?root=<stage>&store=/data/data/com.termux/files/nix/store'` directly (saving the separate Stage-1 build step, as dramforever noted in his post's edit).
3. **Flavor 2 (`installer.*` — Stage 2 Pure Nix):** built *by* Stage 1 Nix with `builtins.storeDir == "/data/data/com.termux/files/nix/store"` (enforced via `assert` in [`bootstrap.nix`](../bootstrap.nix)!).
   - Every binary, shared library, script, `nix`, `home-manager`, and `stdenv` stage genuinely lives in `/data/data/com.termux/files/nix/store` with true custom-prefix hashes.
   - `closureInfo` produces `store-paths` and `registration` directly usable by `nix-store --load-db` with zero post-processing.

### Including All `stdenv` Bootstrap Stages (`allStdenvStages`)

Following dramforever's *"Extra: Packaging with stdenv"*, `bootstrap.nix` walks `targetPkgs.stdenv.__bootPackages.stdenv` recursively until `__raw == true`:

```nix
collectStdenvStages =
  curStage:
  [ curStage ]
  ++ (
    if (curStage ? __bootPackages) && !(curStage.__bootPackages.__raw or false) then
      collectStdenvStages curStage.__bootPackages.stdenv
    else
      [ ]
  );
```

Because these are genuine Stage-2 `/data/data/com.termux/files/nix/store` paths, their hashes match nixpkgs directly on Termux and avoid rebuilding the entire compiler/Bionic bootstrap chain when users build additional packages.

## Home Manager Integration for Termux

- **Termux-patched `home-manager` + wrapped `inetutils` (`hostname`):** Android/Termux lacks `/etc/hosts` or reverse DNS, causing `hostname -f` to exit non-zero and crash `home-manager` under `set -euo pipefail`. Both `home-manager` and `hostname` fall back safely to `localhost`.
- **Reusable module ([`home-manager/termux.nix`](../home-manager/termux.nix)):** Sets Termux-safe defaults (`home.homeDirectory`, disables `systemd.user.startServices`, desktop `xdg.mime`, and `manual.manpages`, provides a non-glibc stub for `i18n.glibcLocales` on Bionic, preserves prefixed `NIX_*` and `TMPDIR` session variables, and sources `termux-nix-env.sh` from managed shells).
- **`termux-home-manager-init`:** Generates `~/.config/home-manager/home.nix` and optional `flake.nix` (`--flake`) configured for the current Termux user and the project's single fixed `aarch64` ISA (`armv8.2-a`).
