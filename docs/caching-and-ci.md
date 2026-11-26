# Binary Caching, GitHub Pages Substituter & VM Testing

## 1. Host / CI Binary Cache (Cachix: `prefix.cachix.org`)

Host and GitHub Actions builds (Stage-1 prefixed `nix-store` / `nix` CLI, Android NDK r27 Bionic cross toolchains, VM tests) are cached on Cachix:

- **Substituter:** `https://prefix.cachix.org`
- **Public key:** `prefix.cachix.org-1:kxW9psUOK2149rGlsQCQ3uD/17460lMtjZxMfOhV9o4=`
- **Flake integration:** Configured in [`flake.nix`](../flake.nix) (`nixConfig.extra-substituters` / `extra-trusted-public-keys`).
- **GitHub Actions:** [`.github/workflows/build-release.yml`](../.github/workflows/build-release.yml) uses `cachix/cachix-action@v15` with `secrets.CACHIX_AUTH_TOKEN` to pull and push build outputs.

> **Note:** `prefix.cachix.org` advertises `StoreDir: /nix/store`, so it accelerates host/CI builds rather than on-device `/data/data/com.termux/files/nix/store` pulls.

---

## 2. On-Device Termux Substituter via GitHub Pages

A Nix HTTP binary cache is purely static files (`nix-cache-info`, `<hash>.narinfo`, `nar/<hash>.nar.zst`). [`.github/workflows/pages-cache.yml`](../.github/workflows/pages-cache.yml) exports pure Stage-2 Bionic `/data/data/com.termux/files/nix/store` paths into a signed static zstd cache advertising `StoreDir: /data/data/com.termux/files/nix/store` and deploys it to GitHub Pages via `actions/deploy-pages`.

### One-Time Setup

1. Generate an Ed25519 signing key pair locally:
   ```bash
   nix key generate-secret --key-name mio-aotearoa.github.io-1 > cache-priv-key.pem
   nix key convert-secret-to-public < cache-priv-key.pem
   ```
2. Save the contents of `cache-priv-key.pem` in **GitHub Repository Settings → Secrets and variables → Actions → `NIX_CACHE_PRIV_KEY`**.
3. Enable **Settings → Pages → Build and deployment → Source: GitHub Actions**.
4. Trigger **Deploy GitHub Pages Nix Substituter** (or push to `main`).
5. On Termux, add the published URL and public key (also served at `/public-key.txt`) to `/data/data/com.termux/files/nix/etc/nix/nix.conf`:
   ```ini
   extra-substituters = https://mio-aotearoa.github.io/nix-prefix
   extra-trusted-public-keys = mio-aotearoa.github.io-1:<base64-public-key>
   ```

> **Limits:** GitHub Pages has a 1 GB soft site limit — well suited for a curated starter Bionic closure. For a multi-GB full nixpkgs binary cache, use Cloudflare R2, S3, or Attic advertising `StoreDir: /data/data/com.termux/files/nix/store`.

The Stage-2 build can exceed the standard GitHub-hosted Linux runner's 14 GB SSD allowance. Both cache-producing workflows therefore remove unused preinstalled Android, .NET, Haskell, and CodeQL payloads before installing Nix. They also set `max-jobs = 2` and `cores = 2`, limiting compiler concurrency on the runner's 16 GB of RAM.

---

## 3. Automated QEMU/KVM VM Test

[`tests/vm-test.nix`](../tests/vm-test.nix) boots a real NixOS QEMU/KVM VM as unprivileged Termux user `u0_a100` (UID `10100`, home `/data/data/com.termux/files/home`) and verifies:

```bash
nix build .#checks.x86_64-linux.vm-test -L
```

1. **dramforever Stage 1 → Stage 2:** Verifies compiled-in `store-dir`, `localstatedir`, `log-dir`, `sysconfdir` in `nixStage1`, genuine builds directly into `/data/data/com.termux/files/nix/store` (zero `patchelf`!), `nix-store --verify --check-contents`, and `bootstrap.nix`'s strict `builtins.storeDir == "/data/data/com.termux/files/nix/store"` Stage-2 invariant.
2. **Android Bionic + Fixed `armv8.2-a` ISA:** Verifies a real cross-compiled `aarch64-unknown-linux-android` (`armv8.2-a`) binary uses `/system/bin/linker64` and `libc.so` (zero glibc), verifies `platforms.nix` fixes `aarch64` to Bionic + `armv8.2-a`, and verifies `home-manager/termux.nix` evaluates cleanly under Bionic.
3. **Home Manager on Termux:** Verifies `termux-home-manager-init`, Termux-patched `home-manager`, and real generation 1 → generation 2 activation under `/data/data/com.termux/files/home` (dotfiles, `~/.bashrc`, `~/.config/git/config`, `hm-session-vars.sh`, `~/.nix-profile/bin/termux-greet`, and `home-manager generations`).
