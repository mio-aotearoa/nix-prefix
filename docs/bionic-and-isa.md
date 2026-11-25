# Android Bionic C Library & Fixed `armv8.2-a` ISA

## Why Bionic Everywhere for Termux?

Because a pure Stage-2 prefixed store (`/data/data/com.termux/files/nix/store`) compiles the entire world from the ground up anyway, `nix-prefix` targets **Android's native Bionic C library everywhere for Termux** (matching Termux itself):

1. **Android 8+ seccomp compliance without maintaining a patched glibc fork** — Stock GNU libc invokes syscalls blocked by Android's seccomp filter on Android 8.0+ (API 26+). Running glibc natively without `proot` requires maintaining a custom patched glibc fork and toolchain; Bionic is built directly for Android's syscall policy.
2. **Native Android library interoperability (graphics, audio, DNS)** — Glibc binaries cannot link against Android's native system libraries. Bionic binaries interoperate directly with Android's native Vulkan, OpenGL ES, OpenSL ES, AAudio, and Android's `netd` DNS resolver (whereas glibc DNS breaks when `/etc/resolv.conf` is absent).
3. **Native system dynamic linker (`/system/bin/linker64`) & zero `proot` overhead** — Bionic executables use Android's built-in dynamic linker instead of shipping a foreign ELF interpreter (aligning with Android/Google Play restrictions) and run directly on the kernel without `proot` ptrace emulation middleware.
4. **No reduction in Android patching burden with glibc** — Most Termux/Android package patches address hardcoded FHS paths (`/tmp`, `/bin/sh`, `/etc`), SELinux/seccomp restrictions, and cross-compilation — none of which disappear under glibc. Switching to glibc only adds a custom libc fork while permanently sacrificing native Android library compatibility.

All Termux targets in [`platforms.nix`](../platforms.nix) use Android NDK r27 Clang + Bionic sysroot (Android API 35, `/system/bin/linker64`, `libc.so`):

| Arch | Target Triple | Fixed ISA (`gcc.arch`) |
|---|---|---|
| `aarch64` | `aarch64-unknown-linux-android` | **`armv8.2-a`** (fixed project-wide) |
| `armv7l` | `armv7a-unknown-linux-androideabi` | baseline |
| `x86_64` | `x86_64-unknown-linux-android` | `x86-64-v2` (fixed) |
| `i686` | `i686-unknown-linux-android` | baseline |

---

## Why One Single Fixed `aarch64` ISA: `armv8.2-a`

Rather than fragmenting builds and caches across multiple ISA variants, `nix-prefix` fixes **`armv8.2-a`** as the single `aarch64` ISA across the entire project:

1. **Runs on virtually every real-world Android phone people actually use (2018–present):**
   - **Cortex-A55 mid-range & 2018–2022 phones:** Snapdragon 680/695/7xx/845/855/865/888, Google Tensor G1/G2, MediaTek Helio G85/G99 & Dimensity 700–1200, Exynos 9810–2100. Because Cortex-A55 LITTLE cores are ARMv8.2-A, any higher ISA (`armv8.4-a`, `armv8.5-a`, `armv9-a`) would crash with `SIGILL` on hundreds of millions of phones still in everyday use.
   - **All 2022–2026 ARMv9 flagships:** Snapdragon 8 Gen 1/2/3, Tensor G3/G4/G5, Dimensity 9000–9400, Exynos 2200/2400 (Cortex-A510/A520/A710/A720/X2/X3/X4).
   - **Qualcomm Snapdragon 8 Elite (Oryon V2):** Galaxy S25, OnePlus 13, Xiaomi 15 (ARMv8.7-A without SVE2 — zero `SIGILL` risk from ARMv9 SVE2 instructions).
2. **Real-world modern ISA gains over 2011 baseline `armv8-a`:**
   - **LSE atomics (`atomics`)** — significant concurrency speedup for Nix, Rust, C++, Go, and memory allocators on multi-core big.LITTLE SoCs.
   - **FP16 (`fphp`/`asimdhp`), RDMA (`asimdrdm`), and CRC32 (`crc32`)** — hardware-accelerated checksums, math, and SIMD.
3. **One unified binary cache:**
   - A single fixed `gcc.arch = "armv8.2-a"` produces **one deterministic store-path hash per package**, so release tarballs, the GitHub Pages `/data/data/com.termux/files/nix/store` binary cache, and on-device Home Manager builds all share the exact same store paths.
   - `install.sh` automatically configures `extra-system-features = gccarch-armv8-a gccarch-armv8.1-a gccarch-armv8.2-a` in `/data/data/com.termux/files/nix/etc/nix/nix.conf`, and `termux-home-manager-init --flake` targets `gcc.arch = "armv8.2-a"` on `aarch64`.
