# Literature Research: Near-Native Native-Code Execution on Non-Jailbroken iOS

This document focuses exclusively on **native-code execution pathways (no WebAssembly)** for running Nix, Unix toolchains, and near-native workloads on **non-jailbroken iOS** devices using sideloading tools.

---

## 1. Fundamental Kernel & Hardware Barriers on Stock iOS

Unlike rootless jailbroken iOS (where `/var/jb/nix` + ad-hoc codesign works — see [`README.md`](README.md)), non-jailbroken iOS enforces three strict walls:

1. **AMFI & TXM Code-Signing Enforcement:** XNU and Apple's hardware-backed Trusted Execution Monitor (TXM on modern Apple Silicon iOS devices) mandate that every executable Mach-O page and dynamically loaded `.dylib` carry an Apple-recognized cryptographic signature. Arbitrary downloaded or on-device-compiled Mach-O binaries cannot be `execve`'d or `dlopen`'d directly.
2. **App Sandbox & `posix_spawn` Restrictions:** Sandboxed iOS apps cannot spawn external Mach-O binaries located inside their writable data container (`Documents`/`Library`).
3. **No Third-Party `Hypervisor.framework` & Restricted JIT (`W^X`):** Apple does not expose `Hypervisor.framework` to third-party iOS apps (unlike macOS). Dynamic code emission (`PROT_EXEC` / JIT) is blocked by `W^X` unless the process is marked `CS_DEBUGGED` via debugger attachment.

---

## 2. Native-Code Sideloading Pathways (No WASM)

| Pathway | Native Mechanism | Execution Speed | Viability for Nix + Home Manager | Key Constraints |
|---|---|---|---|---|
| **1. `LiveContainer` (+ `LiveContainer2` / `LiveProcess`) + `zsign` + `StikDebug`** | Patches guest Mach-O `MH_EXECUTE` -> `MH_DYLIB`, signs on-device with embedded `zsign` using the user's signing cert, loads into the host process via `dlopen()`, hooks `NSBundle`/`dyld` paths, and optionally loads `.dylib` modules via `TweakLoader`. Pairing with **StikDebug** grants `CS_DEBUGGED` / JIT dynamically. | **100% native ARM64 speed** (direct CPU execution, zero translation). | **Experimental / requires major Nix changes:** Single-process Mach-O libraries can run natively via `dlopen`, and `ios_system`-style dispatch can host CLI tools in-process. However, Nix relies deeply on `fork`/`posix_spawn` to run derivation builders, `bash`, `coreutils`, `git`, `tar`, and Home Manager activation scripts. | Stock iOS blocks `posix_spawn` of newly built store binaries; every build output would need `MH_EXECUTE` -> `MH_DYLIB` conversion + `zsign` re-signing + in-process execution, plus 7-day refresh on free Apple IDs. |
| **2. `UTM` (`aarch64-linux` VM) + `StikDebug` (On-Device JIT)** | Sideloaded QEMU running a native `aarch64-linux` kernel/userspace. **StikDebug** (formerly `StikJIT`) + `LocalDevVPN` + a one-time computer-generated `.mobiledevicepairing` file mounts a Developer Disk Image (DDI) over local loopback and attaches as debugger to grant `CS_DEBUGGED` (JIT) with no tethered PC needed. | **Near-native (JIT-compiled ARM64-on-ARM64 TCG)** — fast enough for real Nix evaluation, Home Manager switches, and compilation (slower than `Hypervisor.framework`, vastly faster than interpreted UTM SE). | **100% viable today:** Runs unmodified Linux Nix + Home Manager with standard `/nix/store` and `cache.nixos.org` inside the VM. | Runs inside a VM rather than native iOS userspace; subject to iOS Jetsam RAM limits; requires SideStore/AltStore refresh (7 days on free Apple ID) and StikDebug JIT activation per launch. |
| **3. `TrollStore` (CoreTrust Bug — iOS 14.0–17.0 only)** | Exploits Apple's CoreTrust validation bug to permanently install fake-signed Mach-O binaries with arbitrary entitlements — **no jailbreak**, yet native `posix_spawn` and unsigned/ad-hoc Mach-O execution work directly. | **100% native ARM64 speed**. | **Best native non-jailbroken target on supported iOS versions:** A prefixed store inside the app container (`/var/mobile/Containers/Data/.../nix`) can run native Mach-O Nix + builders directly without SSV `/nix`. | Patched after iOS 17.0; **unavailable** on modern updated iOS (17.1+ / 18+ / 26+). |
| **4. `UTM SE` / `iSH` (JIT-less Interpreted Emulation — App Store)** | Pure software CPU interpretation (`UTM SE` threaded QEMU interpreter; `iSH` 32-bit x86 user-mode syscall translator). | **Slow (NOT near-native)** — ~5–50x overhead. | Technically runs Linux Nix, but far too slow for practical source builds or large Home Manager evaluations. | Included only as baseline contrast to JIT-enabled native pathways above. |

---

## 3. Deep Dive: How Modern Non-Jailbroken Native Execution Works

### A. On-Device Native Mach-O Loading (`LiveContainer` + `zsign` + `LiveProcess`)
- **Mach-O header rewriting:** `LiveContainer` converts guest binaries from `MH_EXECUTE` to `MH_DYLIB` so iOS permits loading them into an already-signed host process via `dlopen()`.
- **On-device signing (`zsign`):** An embedded `zsign` implementation signs imported binaries and `.dylib`s on-device using the host app's provisioning certificate/key so AMFI validates the `dlopen()` call.
- **Process isolation (`LiveProcess` / `NSExtension`):** Uses iOS app extensions (`NSExtension`) and helper process instances (`LiveProcess`) to approximate multi-process execution inside the sandbox, though arbitrary POSIX `fork()`/`execve()` of arbitrary store binaries remains forbidden by XNU.
- **Why this matters for `nix-prefix`:** Running `nix` itself as a `dlopen`'d Mach-O library at full native speed is feasible, and pre-bundled CLI tools could be invoked via an `ios_system`-like in-process dispatcher. Running arbitrary Nix derivation builders (`stdenv`, `gcc`/`clang`, `make`, `bash` subshells) natively without `posix_spawn` remains an unsolved OS-level barrier on non-jailbroken iOS 17.1+.

### B. On-Device JIT Unlocking (`StikDebug` + `LocalDevVPN` + DDI Loopback)
- Modern iOS (including TXM-hardened devices) blocks unsigned executable pages unless `CS_DEBUGGED` is set via Apple's developer debugging protocol (`lockdownd` / `debugserver` / DDI).
- **StikDebug** automates this completely on-device after a one-time pairing file (`.mobiledevicepairing`) is created with a computer (`iLoader` / `SideStore`):
  1. `LocalDevVPN` establishes a local loopback tunnel to the device's own developer interface.
  2. `StikDebug` dynamically mounts the Developer Disk Image (DDI) and attaches to the target PID (including apps hosted inside `LiveContainer` / `LiveContainer2`).
  3. Once `CS_DEBUGGED` is active, **UTM** executes `aarch64-linux` guest code via QEMU's JIT (TCG) at near-native speed.

---

## 4. Practical Verdict for Non-Jailbroken iOS

- **Need near-native Nix + Home Manager on modern non-jailbroken iOS today?**
  Use **SideStore + StikDebug (JIT) + UTM (`aarch64-linux`)** (optionally hosted in **LiveContainer** to save app slots). This gives genuine near-native execution of full Nix + Home Manager + `cache.nixos.org` without a jailbreak or tethered computer.
- **On iOS 14.0–17.0 (TrollStore-eligible)?**
  A native prefixed Mach-O store inside a TrollStore-installed container achieves **100% native speed** with real `posix_spawn` and zero VM overhead.
- **Native non-VM prefixed Nix on modern non-jailbroken iOS (17.1+ / 18+ / 26+)?**
  Only feasible if Nix's builder execution model is reworked around `LiveContainer` + `zsign` + `MH_DYLIB` `dlopen()` / `ios_system` in-process dispatch — otherwise XNU's `posix_spawn` + AMFI/TXM restrictions block arbitrary store executables.
