# Experimental Stage-1 -> Stage-2 bootstrap work for rootless jailbroken iOS (/var/jb/nix)
#
# Architecture: https://dram.page/p/bootstrapping-nix/
#
# Parallel to ../bootstrap.nix (Termux / Android Bionic), with ZERO path-replacing hacks
# (no install_name_tool / Mach-O rewriting):
#   - Store lives at /var/jb/nix (SSV makes /nix on / impossible)
#   - Flavor 1 (`nixStage1`): host Nix (aarch64-darwin) compiled with store-dir=/var/jb/nix/store
#   - Flavor 2 (`installer`): requires a real iOS closure built with builtins.storeDir == "/var/jb/nix/store"
#   - Host: aarch64-darwin (Apple Silicon Mac); target: iOS Darwin (iphone64)
#
# The current nixpkgs iphone64 stdenv cannot build ordinary packages, so the
# default installer path produces a HOST-ONLY research payload. Do not ship it.
# Device payloads must pass ios/validate-payload.sh.
#
# Usage (on aarch64-darwin):
#   # Stage 1:
#   nix-build ios/bootstrap.nix -A nixStage1
#   # Stage 2 (pure dramforever bootstrap):
#   nix-build --store 'local?root=/tmp/ios-stage2&store=/var/jb/nix/store' ios/bootstrap.nix -A installer

{
  pkgs ? import <nixpkgs> { },
}:

# Host must be an Apple Silicon Mac; device target is iOS Darwin (see iosPkgs).
assert
  pkgs.stdenv.hostPlatform.system == "aarch64-darwin"
  || throw "ios/bootstrap.nix must be built on aarch64-darwin (Apple Silicon Mac)";

with pkgs;

let
  jbPrefix = "/var/jb";
  nixPrefix = "${jbPrefix}/nix";
  storeDir = "${nixPrefix}/store";
  localStateDir = "${nixPrefix}/var";
  stateDir = "${nixPrefix}/var/nix";
  logDir = "${nixPrefix}/var/log/nix";
  sysConfDir = "${nixPrefix}/etc";
  confDir = "${nixPrefix}/etc/nix";

  # Intended device target (iOS Darwin — not macOS aarch64-darwin).
  # Used for documentation and future cross rootPaths; swap rootPaths to
  # (mkNixBoot iosPkgs) and iosPkgs.* when iOS cross of Nix works.
  iosPkgs = pkgs.pkgsCross.iphone64;

  mkNixBoot =
    targetPkgs:
    let
      nixComponents = targetPkgs.nixVersions.nixComponents_2_34;
      # Modular nix: nix-store defines store-dir/localstatedir/log-dir/sysconfdir;
      # nix (CLI) asserts its localstatedir matches nix-store's pkg-config localstatedir.
      nixComponentsWithCustomPaths = nixComponents.overrideAllMesonComponents (
        _final: prev: {
          mesonFlags =
            (prev.mesonFlags or [ ])
            ++ targetPkgs.lib.optionals ((prev.pname or "") == "nix-store") [
              (targetPkgs.lib.mesonOption "store-dir" storeDir)
              (targetPkgs.lib.mesonOption "localstatedir" localStateDir)
              (targetPkgs.lib.mesonOption "log-dir" logDir)
              (targetPkgs.lib.mesonOption "sysconfdir" sysConfDir)
            ]
            ++ targetPkgs.lib.optionals ((prev.pname or "") == "nix") [
              (targetPkgs.lib.mesonOption "localstatedir" localStateDir)
              (targetPkgs.lib.mesonOption "sysconfdir" sysConfDir)
            ];
        }
      );
    in
    # nix-everything pulls store tests that assume /nix/store; use the CLI package.
    nixComponentsWithCustomPaths.nix-cli;

  # Flavor 1 (Stage 1) / Stage 2 Nix with /var/jb/nix paths baked in.
  nixStage1 = mkNixBoot pkgs;
  nixBoot = nixStage1;

  # Tiny closure — no full stdenv stage walk (deferred vs Termux bootstrap).
  nixClosure = pkgs.closureInfo {
    rootPaths = [
      nixBoot
      pkgs.bashInteractive
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.gawk
      pkgs.gnutar
      pkgs.gzip
      pkgs.xz
      pkgs.bzip2
      pkgs.curl
      pkgs.cacert
      pkgs.file
    ];
  };

  installerScript = pkgs.writeScript "install.sh" ''
    #!/bin/sh
    set -eu
    SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
    exec "$SCRIPT_DIR/install-payload.sh" --payload-dir "$SCRIPT_DIR"
  '';

  envScript = pkgs.writeText "ios-nix-env.sh" (builtins.readFile ./ios-nix-env.sh);

  # Experimental payload builder. It refuses at build time unless the current
  # store prefix matches /var/jb/nix/store, but the host package choices still
  # need replacing with a working iOS cross closure before this is device-ready.
  installer = pkgs.stdenv.mkDerivation {
    name = "nix-ios-jb-installer";
    nativeBuildInputs = with pkgs.buildPackages; [
      gnutar
      gzip
      coreutils
      file
      darwin.cctools
    ];

    buildCommand = ''
      if [ "${builtins.storeDir}" != "${storeDir}" ]; then
        echo "Pure Stage-2 iOS bootstrap requires builtins.storeDir == ${storeDir}," >&2
        echo "but the current store is ${builtins.storeDir}." >&2
        echo "Build with: nix-build --store 'local?root=/tmp/ios-stage2&store=${storeDir}' ios/bootstrap.nix -A installer" >&2
        exit 1
      fi

      mkdir -p $out/tarball/store
      cd $out/tarball

      echo "Copying candidate store paths (${storeDir})..."
      while IFS= read -r path; do
        [ -n "$path" ] || continue
        storePath=$(basename "$path")
        cp -a "$path" "store/$storePath"
      done < ${nixClosure}/store-paths

      cp ${nixClosure}/registration registration
      cp ${installerScript} install.sh
      cp ${./install-payload.sh} install-payload.sh
      cp ${./sign-store.sh} sign-store.sh
      cp ${./validate-payload.sh} validate-payload.sh
      chmod +x install.sh install-payload.sh sign-store.sh
      cp ${envScript} ios-nix-env.sh

      cat > README.txt << EOF
      Experimental Nix payload for rootless jailbroken iOS
      =====================================================

      Layout:
        Store:  ${storeDir}
        State:  ${stateDir}
        Log:    ${logDir}
        Config: ${confDir}

      Platform notes:
        - Host build: aarch64-darwin
        - Device target: iOS Darwin (iphoneos / pkgsCross.iphone64)
        - /nix on system root is impossible under SSV; use /var/jb/nix
        - allow-symlinked-store required because /var/jb is a symlink
        - Ad-hoc codesign + entitlements required on device

      Installation:
        1. Copy/extract this tarball onto the device (SSH)
        2. Run: ./install.sh
        3. source ${confDir}/ios-nix-env.sh

      Build status:
        The checked-in nixpkgs iPhone cross stdenv does not currently build
        ordinary packages, so this host-closure archive is experimental and
        MUST NOT be treated as device-ready. A device-ready archive must pass
        ios/validate-payload.sh on the macOS build host before distribution.

      First slice ships a small closure (no full stdenv). Build packages from source.
      EOF

      cd $out
      echo "Creating tarball..."
      tar -czf nix-ios-jb-aarch64.tar.gz tarball/
      ln -s nix-ios-jb-aarch64.tar.gz tarball.tar.gz
      ls -lh nix-ios-jb-aarch64.tar.gz

      # Keep the experimental host-closure path honest. A real macOS-built
      # closure cannot pass this iOS Mach-O check and must not be distributed.
      ${./validate-payload.sh} nix-ios-jb-aarch64.tar.gz
    '';
  };

in
{
  # Stage-1 default on host /nix/store; pass --store 'local?root=...&store=/var/jb/nix/store' -A installer for Stage 2.
  default = nixStage1;

  inherit
    nixStage1
    nixBoot
    installer
    nixClosure
    iosPkgs
    mkNixBoot
    ;
  inherit
    jbPrefix
    nixPrefix
    storeDir
    stateDir
    logDir
    confDir
    ;

  # Cross Nix: use `nix-build -A 'mkNixBoot iosPkgs'` only when ready —
  # do not expose a top-level nixBootIos derivation (incomplete cross graph).
}
