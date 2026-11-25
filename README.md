# Prefixed Nix + Home Manager

Run Nix and Home Manager where `/nix` on `/` is unavailable without root or `proot`.

| Track | Platform | Store prefix | Docs |
|---|---|---|---|
| **Termux** (below) | Android Bionic (`aarch64` fixed `armv8.2-a`, `armv7l`, `x86_64` fixed `x86-64-v2`, `i686`) | `/data/data/com.termux/files/nix` | [`docs/architecture.md`](docs/architecture.md) |
| **Rootless iOS** | iOS Darwin (`iphoneos` / `pkgsCross.iphone64`) | `/var/jb/nix` | [`ios/README.md`](ios/README.md) (installer + CI ready; native closure blocked) |

## Quick Install (Termux)

```bash
curl -fsSL https://raw.githubusercontent.com/mio-aotearoa/nix-prefix/main/install-nix-termux.sh | bash
. /data/data/com.termux/files/nix/etc/nix/termux-nix-env.sh
nix --version
home-manager --version
```

## Quick Start: Home Manager on Termux

```bash
# Channel / NIX_PATH mode
termux-home-manager-init
home-manager switch

# Or Flake mode (targets the project's fixed armv8.2-a ISA on aarch64)
termux-home-manager-init --flake
home-manager switch --flake ~/.config/home-manager#$(id -un)
```

Reusable flake module & Android Bionic platform helpers:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    home-manager.url = "github:nix-community/home-manager";
    nix-prefix.url = "github:mio-aotearoa/nix-prefix";
  };

  outputs = { nixpkgs, home-manager, nix-prefix, ... }:
    let
      pkgs = nix-prefix.lib.mkTermuxPkgs {
        inherit nixpkgs;
        arch = "aarch64"; # Android Bionic (aarch64-unknown-linux-android, fixed armv8.2-a)
      };
    in {
      homeConfigurations.termux = home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        modules = [
          nix-prefix.homeManagerModules.termux
          ./home.nix
        ];
      };
    };
}
```

## Building & Testing

Follows [dramforever's pure Stage 1 → Stage 2 bootstrap](https://dram.page/p/bootstrapping-nix/) with **zero `patchelf` / path-replacing hacks**, **Android Bionic C library** everywhere for Termux, and one single fixed `aarch64` ISA (**`armv8.2-a`**):

```bash
# Stage 1: build host Nix driver targeting /data/data/com.termux/files/nix/store
nix build .#nix-stage1

# Stage 2: pure prefixed Android Bionic bootstrap (includes all stdenv stages)
./build.sh -a aarch64

# Automated QEMU/KVM VM test (Stage 1 -> Stage 2 + Bionic + fixed armv8.2-a + Home Manager)
nix build .#checks.x86_64-linux.vm-test -L
```

## Documentation

- [**Architecture & dramforever Stage 1 → Stage 2 Bootstrap**](docs/architecture.md) — Pure prefixed store design (zero path-replacing hacks), `allStdenvStages`, directory layout, Home Manager integration.
- [**Why Bionic & Fixed `armv8.2-a` ISA**](docs/bionic-and-isa.md) — Why Termux uses Android's Bionic C library instead of glibc and why `armv8.2-a` is fixed across the whole project for real-world Android phones.
- [**Binary Caching, GitHub Pages Substituter & CI**](docs/caching-and-ci.md) — Cachix (`prefix.cachix.org`), GitHub Pages static `/data/data/com.termux/files/nix/store` substituter (`NIX_CACHE_PRIV_KEY`), and VM testing.
- [**Rootless iOS Track (`/var/jb/nix`)**](ios/README.md) — Transactional iOS installer, payload validator, signing helper, Apple Silicon CI; native Nix closure still blocked.
- [**Non-Jailbroken iOS Native-Code Research**](ios/non-jailbroken-research.md) — Literature review of native-code near-native execution pathways (`LiveContainer` + `zsign` + `StikDebug`, `UTM + StikDebug` JIT, `TrollStore`).

## License

MIT License. Nix itself is licensed under LGPL 2.1. Based on [dramforever's *Bootstrapping Nix*](https://dram.page/p/bootstrapping-nix/).
