# Target platform, Android Bionic C library, and single fixed Android CPU ISA
# definitions for nix-prefix (Termux / Android).
#
# Because a prefixed Nix store (/data/data/com.termux/files/nix/store) compiles
# the entire world from the ground up (dramforever Stage 1 -> Stage 2), Termux
# targets use:
#   1. Android's native Bionic C library everywhere (matching Termux's ABI,
#      Android 8+ seccomp syscall policy, /system/bin/linker64, and native
#      Android libs such as Vulkan, OpenGL ES, OpenSL ES, AAudio, and netd DNS).
#   2. One single fixed aarch64 ISA across the entire project: `armv8.2-a`.
#      - Runs on virtually every 64-bit Android phone in real-world use (2018-present):
#        Cortex-A55 mid-range phones, 2018-2022 flagships, all ARMv9 flagships,
#        and Qualcomm Snapdragon 8 Elite (Oryon V2, ARMv8.7-A without SVE2).
#      - Enables modern LSE atomics, RDMA, FP16, and CRC32 over 2011 armv8-a.
#      - Keeps one deterministic store-path hash per package so release tarballs,
#        GitHub Pages binary caches, and on-device builds all match.

{ lib }:

rec {
  # Single fixed Android aarch64 ISA for the entire project
  androidAarch64GccArch = "armv8.2-a";

  # Android Bionic architecture specs for Termux (one fixed ISA per arch)
  supportedArchs = {
    aarch64 = {
      name = "aarch64";
      system = "aarch64-linux";
      bionicConfig = "aarch64-unknown-linux-android";
      gccArch = androidAarch64GccArch;
      systemFeatures = [
        "gccarch-armv8-a"
        "gccarch-armv8.1-a"
        "gccarch-armv8.2-a"
      ];
    };
    armv7l = {
      name = "armv7l";
      system = "armv7l-linux";
      bionicConfig = "armv7a-unknown-linux-androideabi";
      gccArch = null;
      systemFeatures = [ "gccarch-armv7-a" ];
    };
    x86_64 = {
      name = "x86_64";
      system = "x86_64-linux";
      bionicConfig = "x86_64-unknown-linux-android";
      gccArch = "x86-64-v2";
      systemFeatures = [
        "gccarch-x86-64"
        "gccarch-x86-64-v2"
      ];
    };
    i686 = {
      name = "i686";
      system = "i686-linux";
      bionicConfig = "i686-unknown-linux-android";
      gccArch = null;
      systemFeatures = [ ];
    };
  };

  # Construct the fixed Bionic crossSystem attrset for a Termux architecture.
  mkTargetSystem =
    {
      arch ? "aarch64",
      androidSdkVersion ? "35",
      androidNdkVersion ? "27",
      # NDK r27 prebuilt Clang + Bionic sysroot avoids upstream LLVM 21
      # no-libc compiler-rt pthread.h bootstrap breakage on aarch64-android.
      useAndroidPrebuilt ? true,
    }:
    let
      archCfg =
        supportedArchs.${arch}
          or (throw "Unsupported arch '${arch}'. Supported: ${lib.concatStringsSep ", " (builtins.attrNames supportedArchs)}");
      gccAttr = lib.optionalAttrs (archCfg.gccArch != null) {
        gcc.arch = archCfg.gccArch;
      };
    in
    {
      config = archCfg.bionicConfig;
      inherit androidSdkVersion androidNdkVersion useAndroidPrebuilt;
      useLLVM = !useAndroidPrebuilt;
    }
    // gccAttr;

  # Instantiate Bionic nixpkgs for Termux using the project's fixed ISA.
  mkTermuxPkgs =
    {
      nixpkgs,
      localSystem ? builtins.currentSystem,
      arch ? "aarch64",
      androidSdkVersion ? "35",
      androidNdkVersion ? "27",
      # Google's prebuilt Android NDK ships x86_64-linux and darwin host binaries;
      # fall back to source-built LLVM (`useLLVM = true`) on aarch64-linux hosts.
      useAndroidPrebuilt ? lib.elem localSystem [
        "x86_64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ],
      overlays ? [ ],
      config ? { },
    }:
    let
      targetSystem = mkTargetSystem {
        inherit
          arch
          androidSdkVersion
          androidNdkVersion
          useAndroidPrebuilt
          ;
      };
      effectiveConfig =
        (lib.optionalAttrs useAndroidPrebuilt {
          allowUnfree = true;
        })
        // config;
    in
    import nixpkgs {
      inherit localSystem overlays;
      config = effectiveConfig;
      crossSystem = targetSystem;
    };
}
