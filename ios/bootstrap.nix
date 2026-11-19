# Bootstrap Nix for rootless jailbroken iOS with custom prefix under /var/jb
#
# Parallel to ../bootstrap.nix (Termux / aarch64-linux), but:
#   - Store lives at /var/jb/nix (SSV makes /nix on / impossible)
#   - Mach-O path rewrite via install_name_tool (not patchelf)
#   - Host: aarch64-darwin (Apple Silicon Mac); target: iOS Darwin (iphone64)
#
# First slice: small closure (Nix + essentials). Full stdenv bootstrap is deferred.
# Device binaries also need ad-hoc codesign + entitlements (Procursus-style).
#
# Usage (on aarch64-darwin):
#   nix-build ios/bootstrap.nix -A installer

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
  stateDir = "${nixPrefix}/var";
  confDir = "${nixPrefix}/etc";

  # Intended device target (iOS Darwin — not macOS aarch64-darwin).
  # Used for documentation and future cross rootPaths; first-slice closure
  # is built on the host so the store-dir + install_name_tool pipeline works.
  iosPkgs = pkgs.pkgsCross.iphone64;

  mkNixBoot =
    targetPkgs:
    let
      nixComponents = targetPkgs.nixVersions.nixComponents_2_31;
      nixComponentsWithCustomPaths = nixComponents.overrideAllMesonComponents (
        _final: prev: {
          mesonFlags = (prev.mesonFlags or [ ]) ++ [
            (targetPkgs.lib.mesonOption "libstore:store-dir" storeDir)
            (targetPkgs.lib.mesonOption "libstore:localstatedir" stateDir)
            (targetPkgs.lib.mesonOption "libstore:sysconfdir" confDir)
          ];
        }
      );
    in
    nixComponentsWithCustomPaths.nix-everything;

  # First slice: host Nix with /var/jb paths baked in (develop rewrite/install).
  # Swap rootPaths to (mkNixBoot iosPkgs) and iosPkgs.* when iOS cross of Nix works.
  nixBoot = mkNixBoot pkgs;

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
        set -e

        JB_PREFIX="${jbPrefix}"
        NIX_PREFIX="${nixPrefix}"
        STORE_DIR="${storeDir}"
        STATE_DIR="${stateDir}"
        CONF_DIR="${confDir}"

        echo "======================================"
        echo "Nix Installer for rootless iOS"
        echo "======================================"
        echo ""
        echo "Target prefix: $NIX_PREFIX"
        echo "Store directory: $STORE_DIR"
        echo "State directory: $STATE_DIR"
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
        mkdir -p "$STATE_DIR/nix/db"
        mkdir -p "$STATE_DIR/nix/gcroots"
        mkdir -p "$STATE_DIR/nix/profiles"
        mkdir -p "$STATE_DIR/nix/temproots"
        mkdir -p "$CONF_DIR/nix"

        echo "Copying store paths..."
        echo "(Mach-O install names have been rewritten during build)"
        cp -R ./store/* "$STORE_DIR/" || true

        echo "Initializing Nix database..."
        if [ -f ./registration ]; then
          NIX_STORE_BIN=$(find "$STORE_DIR" -name "nix-store" -type f | head -n 1)
          if [ -n "$NIX_STORE_BIN" ]; then
            export NIX_STORE_DIR="$STORE_DIR"
            export NIX_STATE_DIR="$STATE_DIR"
            export NIX_CONF_DIR="$CONF_DIR"
            "$NIX_STORE_BIN" --load-db < ./registration
            echo "Database initialized successfully."
          else
            echo "WARNING: Could not find nix-store binary. Database not initialized."
          fi
        fi

        mkdir -p "$STATE_DIR/nix/profiles/per-user/''${USER:-mobile}"
        ln -sf "$STATE_DIR/nix/profiles/per-user/''${USER:-mobile}/profile" \
          "$STATE_DIR/nix/profiles/default" || true

        echo "Creating nix.conf..."
        cat > "$CONF_DIR/nix/nix.conf" << EOF
    # Nix configuration for rootless jailbroken iOS
    # Store prefix: ${storeDir}
    build-users-group =
    sandbox = false
    max-jobs = auto
    cores = 0

    # /var/jb is a symlink into preboot
    allow-symlinked-store = true

    # No official cache for custom prefix
    substituters =
    trusted-public-keys =

    keep-build-log = true
    auto-optimise-store = true
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
        echo "  export NIX_CONF_DIR=\"$CONF_DIR\""
        echo "  export PATH=\"$STATE_DIR/nix/profiles/default/bin:\$PATH\""
        echo ""
  '';

  # Rewrite /nix/store → /var/jb/nix/store in Mach-O load commands.
  rewriteMachOInstallNames = ''
    echo ""
    echo "Rewriting Mach-O install names..."
    echo "  /nix/store -> ${storeDir}"
    echo ""

    PATCHED=0
    SKIPPED=0
    TOTAL_MACHO=0

    # install_name_tool is provided by cctools / Xcode CLT on the build Mac
    if ! command -v install_name_tool >/dev/null 2>&1; then
      echo "ERROR: install_name_tool not found on build host"
      exit 1
    fi
    if ! command -v otool >/dev/null 2>&1; then
      echo "ERROR: otool not found on build host"
      exit 1
    fi

    # NUL-delimited find via process substitution (keeps counters in this shell)
    while IFS= read -r -d $'\0' file; do
      FT=$(file -b "$file" 2>/dev/null || true)
      case "$FT" in
        *Mach-O*) ;;
        *) continue ;;
      esac
      TOTAL_MACHO=$((TOTAL_MACHO + 1))

      DEPS=$(otool -L "$file" 2>/dev/null | awk '/\/nix\/store\// { print $1 }' || true)
      ID=$(otool -D "$file" 2>/dev/null | awk 'NR==2 { print $1 }' || true)

      CHANGED=0

      if [ -n "$ID" ] && echo "$ID" | grep -q '^/nix/store/'; then
        NEW_ID=$(echo "$ID" | sed 's|^/nix/store|${storeDir}|')
        if install_name_tool -id "$NEW_ID" "$file" 2>/dev/null; then
          CHANGED=1
        fi
      fi

      for dep in $DEPS; do
        case "$dep" in
          /nix/store/*)
            NEW_DEP=$(echo "$dep" | sed 's|^/nix/store|${storeDir}|')
            if install_name_tool -change "$dep" "$NEW_DEP" "$file" 2>/dev/null; then
              CHANGED=1
            fi
            ;;
        esac
      done

      if [ "$CHANGED" -eq 1 ]; then
        PATCHED=$((PATCHED + 1))
        if [ "$PATCHED" -le 10 ]; then
          echo "  patched $(basename "$file")"
        elif [ "$PATCHED" -eq 11 ]; then
          echo "  ... (showing first 10, continuing silently)"
        fi
      else
        SKIPPED=$((SKIPPED + 1))
      fi
    done < <(find store -type f -print0)

    echo ""
    echo "Mach-O rewrite results:"
    echo "  Mach-O files seen: $TOTAL_MACHO"
    echo "  Patched: $PATCHED"
    echo "  Unchanged/skipped: $SKIPPED"
    echo ""
  '';

  envScript = pkgs.writeText "ios-nix-env.sh" (builtins.readFile ./ios-nix-env.sh);

  installer = pkgs.stdenv.mkDerivation {
    name = "nix-ios-jb-installer";
    # Prefer nixpkgs cctools; fall back to /usr/bin via PATH from the Mac CLT.
    nativeBuildInputs =
      with pkgs.buildPackages;
      [
        gnutar
        gzip
        coreutils
        findutils
        file
        gnused
        gawk
      ]
      ++ lib.optionals (pkgs.buildPackages ? darwin && pkgs.buildPackages.darwin ? cctools) [
        pkgs.buildPackages.darwin.cctools
      ];

    buildCommand = ''
            mkdir -p $out/tarball
            cd $out/tarball

            mkdir -p store
            echo "Copying store paths..."
            for path in $(cat ${nixClosure}/store-paths); do
              echo "  Copying: $path"
              storePath=$(basename "$path")
              cp -rL "$path" "store/$storePath"
            done

            ${rewriteMachOInstallNames}

            cp ${nixClosure}/registration registration
            cp ${installerScript} install.sh
            chmod +x install.sh
            cp ${envScript} ios-nix-env.sh

            cat > README.txt << EOF
      Nix Bootstrap Installer for rootless jailbroken iOS
      ===================================================

      Layout:
        Store:  ${storeDir}
        State:  ${stateDir}
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
  # default so `nix-build ios/bootstrap.nix` does not build every attr
  default = installer;

  inherit
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
    confDir
    ;

  # Cross Nix: use `nix-build -A 'mkNixBoot iosPkgs'` only when ready —
  # do not expose a top-level nixBootIos derivation (incomplete cross graph).
}
