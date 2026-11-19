# Bootstrap Nix for Termux with custom prefix
#
# References:
# - https://dram.page/p/bootstrapping-nix/ (bootstrap approach)
#
# This builds a Nix installation for /data/data/com.termux/files/nix
# Targeting: multiple architectures for Termux
#
# Approach: Build for /nix/store, then use patchelf to rewrite interpreter paths.
#
# Usage:
#   nix-build bootstrap.nix -A installer.aarch64
#   nix-build bootstrap.nix -A installer.armv7l --arg crossSystem '{ config = "armv7l-unknown-linux-gnueabihf"; }'
#
# Or via ./build.sh -a <arch>

{
  crossSystem ? null,
  system ? builtins.currentSystem,
  nixpkgs ? <nixpkgs>,
  # Re-evaluated with crossSystem when --arg crossSystem=... is passed
  pkgs ? import nixpkgs { inherit system crossSystem; },
}:

with pkgs;

let
  supportedArchs = {
    aarch64 = {
      targetPlatform = "aarch64-unknown-linux-gnu";
      name = "aarch64";
    };
    armv7l = {
      targetPlatform = "armv7l-unknown-linux-gnueabihf";
      name = "armv7l";
    };
    x86_64 = {
      targetPlatform = "x86_64-unknown-linux-gnu";
      name = "x86_64";
    };
    i686 = {
      targetPlatform = "i686-unknown-linux-gnu";
      name = "i686";
    };
  };

  makeInstaller =
    { targetPlatform, name }:
    let
      termuxPrefix = "/data/data/com.termux/files";
      nixPrefix = "${termuxPrefix}/nix";
      storeDir = "${nixPrefix}/store";
      stateDir = "${nixPrefix}/var";
      confDir = "${nixPrefix}/etc";

      nixBoot =
        let
          # Channel removed nixComponents_2_31; keep in sync with available nixVersions.
          nixComponents = pkgs.nixVersions.nixComponents_2_34;

          # Modular nix: only nix-store defines store-dir / localstatedir / sysconfdir.
          nixComponentsWithCustomPaths = nixComponents.overrideAllMesonComponents (
            _final: prev: {
              mesonFlags =
                (prev.mesonFlags or [ ])
                ++ lib.optionals ((prev.pname or "") == "nix-store") [
                  (lib.mesonOption "store-dir" storeDir)
                  (lib.mesonOption "localstatedir" stateDir)
                  (lib.mesonOption "sysconfdir" confDir)
                ];
            }
          );
        in
        # nix-everything pulls store tests that assume /nix/store; use the CLI package.
        nixComponentsWithCustomPaths.nix-cli;

      collectStdenvStages =
        curStage:
        [ curStage ]
        ++ (
          if (curStage ? __bootPackages) && !(curStage.__bootPackages.__raw or false) then
            collectStdenvStages curStage.__bootPackages.stdenv
          else
            [ ]
        );

      allStdenvStages = collectStdenvStages pkgs.stdenv;

      nixClosure = pkgs.closureInfo {
        rootPaths = [
          nixBoot
        ]
        ++ allStdenvStages
        ++ [
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
          pkgs.wget
          pkgs.git
          pkgs.cacert
          pkgs.gnumake
          pkgs.patch
          pkgs.diffutils
          pkgs.which
          pkgs.patchelf
          pkgs.file
          pkgs.less
          pkgs.nano
        ];
      };

      installerScript = pkgs.writeScript "install.sh" ''
                #!/bin/sh
                set -e

                TERMUX_PREFIX="${termuxPrefix}"
                NIX_PREFIX="${nixPrefix}"
                STORE_DIR="${storeDir}"
                STATE_DIR="${stateDir}"
                CONF_DIR="${confDir}"
                EXPECTED_ARCH="${name}"

                echo "======================================"
                echo "Nix Installer for Termux ($EXPECTED_ARCH)"
                echo "======================================"
                echo ""
                echo "Target prefix: $NIX_PREFIX"
                echo "Store directory: $STORE_DIR"
                echo ""

                ARCH=$(uname -m)
                if [ "$ARCH" != "$EXPECTED_ARCH" ]; then
                  echo "ERROR: This installer is for $EXPECTED_ARCH only. Detected: $ARCH"
                  exit 1
                fi

                if [ ! -d "$TERMUX_PREFIX" ]; then
                  echo "WARNING: $TERMUX_PREFIX not found. Are you running this in Termux?"
                  echo "Press Ctrl+C to cancel, or Enter to continue anyway..."
                  read
                fi

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
                cp -r ./store/* "$STORE_DIR/" || true

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

                mkdir -p "$STATE_DIR/nix/profiles/per-user/$USER"
                ln -sf "$STATE_DIR/nix/profiles/per-user/$USER/profile" \
                  "$STATE_DIR/nix/profiles/default" || true

                echo "Creating nix.conf..."
                cat > "$CONF_DIR/nix/nix.conf" << EOF
        # Nix configuration for Termux ($EXPECTED_ARCH)
        build-users-group =
        sandbox = false
        max-jobs = auto
        cores = 0
        substituters =
        trusted-public-keys =
        EOF

                echo ""
                echo "Installation complete!"
                echo "Add to ~/.bashrc or ~/.zshrc:"
                echo "  export NIX_STORE_DIR=\"$STORE_DIR\""
                echo "  export NIX_STATE_DIR=\"$STATE_DIR\""
                echo "  export NIX_CONF_DIR=\"$CONF_DIR\""
                echo "  export PATH=\"$STATE_DIR/nix/profiles/default/bin:\$PATH\""
                echo ""
      '';

      installer = pkgs.stdenv.mkDerivation {
        name = "nix-termux-installer-${name}";
        nativeBuildInputs = with pkgs.buildPackages; [
          gnutar
          gzip
          coreutils
          findutils
          patchelf
          file
          gnused
          gawk
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

                    # Store objects are read-only; patchelf needs writable files
                    chmod -R u+w store

                    echo ""
                    echo "Patching ELF interpreter paths..."
                    echo "Rewriting /nix/store -> ${storeDir}"
                    echo ""

                    PATCHED_COUNT=0
                    TOTAL_ELF=0
                    SKIPPED_COUNT=0

                    while IFS= read -r file; do
                      FILE_TYPE=$(file "$file" 2>/dev/null || echo "")
                      if echo "$FILE_TYPE" | grep -q "ELF.*interpreter"; then
                        TOTAL_ELF=$((TOTAL_ELF + 1))
                        INTERP=$(patchelf --print-interpreter "$file" 2>/dev/null || true)

                        if [ -n "$INTERP" ] && echo "$INTERP" | grep -q "^/nix/store"; then
                          NEW_INTERP=$(echo "$INTERP" | sed 's|^/nix/store|${storeDir}|')
                          INTERP_RELATIVE=$(echo "$INTERP" | sed 's|^/nix/store/||')

                          if [ -f "store/$INTERP_RELATIVE" ] || [ -L "store/$INTERP_RELATIVE" ]; then
                            if patchelf --set-interpreter "$NEW_INTERP" "$file" 2>/dev/null; then
                              PATCHED_COUNT=$((PATCHED_COUNT + 1))
                              if [ "$PATCHED_COUNT" -le 10 ]; then
                                echo "  patched $(basename "$file"): $NEW_INTERP"
                              elif [ "$PATCHED_COUNT" -eq 11 ]; then
                                echo "  ... (showing first 10, continuing silently)"
                              fi
                            fi
                          else
                            # Soft-skip missing interpreters (e.g. system libc); do not fail the build
                            SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
                            if [ "$SKIPPED_COUNT" -le 5 ]; then
                              echo "  skipped $(basename "$file"): interpreter not in closure ($INTERP_RELATIVE)"
                            fi
                          fi
                        fi
                      fi
                    done < <(find store -type f -executable)

                    echo ""
                    echo "Results:"
                    echo "  ELF with interpreter: $TOTAL_ELF"
                    echo "  Successfully patched: $PATCHED_COUNT"
                    echo "  Skipped: $SKIPPED_COUNT"
                    echo ""

                    cp ${nixClosure}/registration registration
                    cp ${installerScript} install.sh
                    chmod +x install.sh

                    cat > README.txt << EOF
          Nix Bootstrap Installer for Termux (${name})
          ===================================================

          Store:  ${storeDir}
          State:  ${stateDir}
          Config: ${confDir}

          Installation:
            1. Extract this tarball
            2. Run: ./install.sh
          EOF

                    cd $out
                    echo "Creating tarball..."
                    tar -czf nix-termux-${name}.tar.gz tarball/
                    ln -s nix-termux-${name}.tar.gz tarball.tar.gz
                    ls -lh nix-termux-${name}.tar.gz
        '';
      };
    in
    {
      inherit
        installer
        nixBoot
        nixClosure
        storeDir
        stateDir
        confDir
        ;
    };

  archInstallers = lib.mapAttrs (_name: config: (makeInstaller config).installer) supportedArchs;

in
{
  installer = archInstallers;
  inherit supportedArchs;

  # Convenience: native default when attrs are selected without .arch
  default = archInstallers.aarch64;
}
