# Pure dramforever Stage-1 -> Stage-2 Bootstrap of Nix for rootless jailbroken iOS (/var/jb/nix)
#
# Architecture: https://dram.page/p/bootstrapping-nix/
#
# Parallel to ../bootstrap.nix (Termux / Android Bionic), with ZERO path-replacing hacks
# (no install_name_tool / Mach-O rewriting):
#   - Store lives at /var/jb/nix (SSV makes /nix on / impossible)
#   - Flavor 1 (`nixStage1`): host Nix (aarch64-darwin) compiled with store-dir=/var/jb/nix/store
#   - Flavor 2 (`installer`): pure Stage-2 closure built with builtins.storeDir == "/var/jb/nix/store"
#   - Host: aarch64-darwin (Apple Silicon Mac); target: iOS Darwin (iphone64)
#
# First slice: small closure (Nix + essentials). Full stdenv bootstrap is deferred.
# Device binaries also need ad-hoc codesign + entitlements (Procursus-style).
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
  builtins.currentSystem == "aarch64-darwin"
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

    JB_PREFIX="${jbPrefix}"
    NIX_PREFIX="${nixPrefix}"
    STORE_DIR="${storeDir}"
    STATE_DIR="${stateDir}"
    LOG_DIR="${logDir}"
    CONF_DIR="${confDir}"
    NIX_STORE_BIN="${nixBoot}/bin/nix-store"

    echo "======================================"
    echo "Nix Installer for rootless iOS (Pure Stage-2)"
    echo "======================================"
    echo ""
    echo "Target prefix:    $NIX_PREFIX"
    echo "Store directory:  $STORE_DIR"
    echo "State directory:  $STATE_DIR"
    echo "Log directory:    $LOG_DIR"
    echo "Config directory: $CONF_DIR"
    echo ""

    ARCH=$(uname -m)
    case "$ARCH" in
      arm64|aarch64) ;;
      *)
        echo "ERROR: aarch64/arm64 only. Detected: $ARCH"
        exit 1
        ;;
    esac

    if [ ! -d "$JB_PREFIX" ] && [ ! -L "$JB_PREFIX" ]; then
      echo "ERROR: $JB_PREFIX not found."
      echo "This installer requires a rootless jailbreak (Dopamine/Procursus-style)."
      exit 1
    fi

    echo "NOTE: /var/jb is a symlink into preboot. allow-symlinked-store is enabled."
    echo "NOTE: Binaries may need ad-hoc codesign + entitlements before they will run."
    echo ""

    echo "Creating directories..."
    if [ -d "$STORE_DIR" ]; then
      echo "Existing store found. Removing old installation..."
      chmod -R u+w "$STORE_DIR" 2>/dev/null || true
      rm -rf "$STORE_DIR"
    fi

    mkdir -p "$STORE_DIR"
    mkdir -p "$STATE_DIR/db"
    mkdir -p "$STATE_DIR/gcroots"
    mkdir -p "$STATE_DIR/profiles/per-user/''${USER:-mobile}"
    mkdir -p "$STATE_DIR/temproots"
    mkdir -p "$LOG_DIR/drvs"
    mkdir -p "$CONF_DIR"

    echo "Copying pure Stage-2 store paths..."
    cp -a ./store/. "$STORE_DIR/"

    echo "Initializing Nix database..."
    if [ -f ./registration ]; then
      if [ -x "$NIX_STORE_BIN" ]; then
        export NIX_STORE_DIR="$STORE_DIR"
        export NIX_STATE_DIR="$STATE_DIR"
        export NIX_LOG_DIR="$LOG_DIR"
        export NIX_CONF_DIR="$CONF_DIR"
        "$NIX_STORE_BIN" --load-db < ./registration
        echo "Database initialized successfully."
      else
        echo "WARNING: Could not find nix-store binary at $NIX_STORE_BIN. Database not initialized."
      fi
    fi

    ln -sfn "$STATE_DIR/profiles/per-user/''${USER:-mobile}/profile" \
      "$STATE_DIR/profiles/default" || true

    echo "Creating nix.conf..."
    cat > "$CONF_DIR/nix.conf" << EOF
    # Nix configuration for rootless jailbroken iOS
    # Store prefix: ${storeDir}
    build-users-group =
    sandbox = false
    experimental-features = nix-command flakes
    max-jobs = auto
    cores = 0

    # /var/jb is a symlink into preboot
    allow-symlinked-store = true

    # No official cache for custom prefix
    substituters =
    trusted-public-keys =

    keep-build-log = true
    auto-optimise-store = false
    EOF

    if [ -f ./ios-nix-env.sh ]; then
      cp ./ios-nix-env.sh "$CONF_DIR/ios-nix-env.sh"
      chmod 644 "$CONF_DIR/ios-nix-env.sh"
    fi

    echo ""
    echo "======================================"
    echo "Installation complete!"
    echo "======================================"
    echo ""
    echo "Add to your shell rc, then re-source:"
    echo "  source $CONF_DIR/ios-nix-env.sh"
    echo ""
    echo "Or:"
    echo "  export NIX_STORE_DIR=\"$STORE_DIR\""
    echo "  export NIX_STATE_DIR=\"$STATE_DIR\""
    echo "  export NIX_LOG_DIR=\"$LOG_DIR\""
    echo "  export NIX_CONF_DIR=\"$CONF_DIR\""
    echo "  export PATH=\"$STATE_DIR/profiles/default/bin:\$PATH\""
    echo ""
  '';

  envScript = pkgs.writeText "ios-nix-env.sh" (builtins.readFile ./ios-nix-env.sh);

  # Pure dramforever Stage-2 installer: requires builtins.storeDir == /var/jb/nix/store
  # (zero install_name_tool / path-replacing hacks).
  installer =
    assert
      builtins.storeDir == storeDir
      || throw ''
        Pure Stage-2 iOS bootstrap requires builtins.storeDir == "${storeDir}",
        but current builtins.storeDir is "${builtins.storeDir}".

        Build Stage 2 using Stage-1 Nix or `--store`:
          nix-build --store 'local?root=/tmp/ios-stage2&store=${storeDir}' ios/bootstrap.nix -A installer
      '';
    pkgs.stdenv.mkDerivation {
      name = "nix-ios-jb-installer";
      nativeBuildInputs = with pkgs.buildPackages; [
        gnutar
        gzip
        coreutils
      ];

      buildCommand = ''
        mkdir -p $out/tarball/store
        cd $out/tarball

        echo "Copying pure Stage-2 store paths (${storeDir})..."
        while IFS= read -r path; do
          [ -n "$path" ] || continue
          storePath=$(basename "$path")
          cp -a "$path" "store/$storePath"
        done < ${nixClosure}/store-paths

        cp ${nixClosure}/registration registration
        cp ${installerScript} install.sh
        chmod +x install.sh
        cp ${envScript} ios-nix-env.sh

        cat > README.txt << EOF
        Nix Pure Stage-2 Bootstrap Installer for rootless jailbroken iOS
        ================================================================

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

        First slice ships a small closure (no full stdenv). Build packages from source.
        EOF

        cd $out
        echo "Creating tarball..."
        tar -czf nix-ios-jb-aarch64.tar.gz tarball/
        ln -s nix-ios-jb-aarch64.tar.gz tarball.tar.gz
        ls -lh nix-ios-jb-aarch64.tar.gz
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
