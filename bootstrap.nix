# Pure dramforever Stage-1 -> Stage-2 Bootstrap of Nix + Home Manager for Termux
#
# Architecture: https://dram.page/p/bootstrapping-nix/
#
# ZERO path-replacing / patchelf hacks:
#   - Flavor 0 (Normal host Nix): lives in /nix/store, operates on /nix/store.
#   - Flavor 1 (`nixStage1`):     built by host Nix, lives in /nix/store, configured
#                                 with store-dir = /data/data/com.termux/files/nix/store
#                                 (or use modern `nix --store 'local?root=...&store=/data/data/com.termux/files/nix/store'`).
#   - Flavor 2 (`installer.*`):   built BY Stage-1 Nix with
#                                 `builtins.storeDir == "/data/data/com.termux/files/nix/store"`.
#                                 Every binary, shared library, script, Home Manager,
#                                 and every stdenv bootstrap stage (`allStdenvStages`)
#                                 is genuinely compiled for `/data/data/com.termux/files/nix/store`
#                                 using Android's native Bionic C library and the single fixed
#                                 Android aarch64 ISA (`armv8.2-a`).
#
# Usage:
#   # Stage 1 (host Nix): build Stage-1 Nix driver targeting /data/data/com.termux/files/nix/store
#   nix build .#nix-stage1
#
#   # Stage 2 (pure dramforever bootstrap): build genuine Bionic Termux tarball
#   ./build.sh -a aarch64
#   ./scripts/build-stage2.sh -a aarch64

{
  crossSystem ? null,
  system ? builtins.currentSystem,
  nixpkgs ? <nixpkgs>,
  pkgs ? import nixpkgs { inherit system crossSystem; },
}:

let
  inherit (pkgs) lib;
  platforms = import ./platforms.nix { inherit lib; };
  inherit (platforms) supportedArchs androidAarch64GccArch;

  termuxPrefix = "/data/data/com.termux/files";
  nixPrefix = "${termuxPrefix}/nix";
  storeDir = "${nixPrefix}/store";
  # Meson appends `/nix` to localstatedir and sysconfdir:
  #   localstatedir = .../var      -> NIX_STATE_DIR = .../var/nix
  #   sysconfdir    = .../etc      -> NIX_CONF_DIR  = .../etc/nix
  #   log-dir       = .../var/log/nix (absolute, not suffixed)
  localStateDir = "${nixPrefix}/var";
  stateDir = "${nixPrefix}/var/nix";
  logDir = "${nixPrefix}/var/log/nix";
  sysConfDir = "${nixPrefix}/etc";
  confDir = "${nixPrefix}/etc/nix";

  # Helper: compile Nix 2.34 with /data/data/com.termux/files/nix paths baked into
  # both nix-store (libstore) and nix (CLI).
  mkPrefixedNix =
    targetPkgs:
    let
      tlib = targetPkgs.lib;
      nixComponents = targetPkgs.nixVersions.nixComponents_2_34;
      nixComponentsWithCustomPaths = nixComponents.overrideAllMesonComponents (
        _final: prev: {
          mesonFlags =
            (prev.mesonFlags or [ ])
            ++ tlib.optionals ((prev.pname or "") == "nix-store") [
              (tlib.mesonOption "store-dir" storeDir)
              (tlib.mesonOption "localstatedir" localStateDir)
              (tlib.mesonOption "log-dir" logDir)
              (tlib.mesonOption "sysconfdir" sysConfDir)
            ]
            ++ tlib.optionals ((prev.pname or "") == "nix") [
              (tlib.mesonOption "localstatedir" localStateDir)
              (tlib.mesonOption "sysconfdir" sysConfDir)
            ];
        }
      );
    in
    nixComponentsWithCustomPaths.nix-cli;

  # Flavor 1 (dramforever Stage 1): lives on host (/nix/store), operates on
  # /data/data/com.termux/files/nix/store.
  nixStage1 = mkPrefixedNix pkgs;

  # Wrap inetutils' hostname so `hostname -f` never exits non-zero on Android/Termux
  # (home-manager runs under `set -euo pipefail` and calls `hostname -f` during flake lookup).
  mkInetutilsTermux =
    targetPkgs:
    targetPkgs.runCommand "inetutils-termux-${targetPkgs.inetutils.version}"
      {
        meta = builtins.removeAttrs (targetPkgs.inetutils.meta or { }) [ "outputsToInstall" ];
      }
      ''
        mkdir -p $out/bin
        for bin in ${targetPkgs.inetutils}/bin/*; do
          bn=$(basename "$bin")
          if [ "$bn" = "hostname" ]; then
            cat > "$out/bin/hostname" << 'EOF'
        #!${targetPkgs.bash}/bin/bash
        if out=$("${targetPkgs.inetutils}/bin/hostname" "$@" 2>/dev/null) && [ -n "$out" ]; then
          printf '%s\n' "$out"
        elif out=$("${targetPkgs.inetutils}/bin/hostname" 2>/dev/null) && [ -n "$out" ]; then
          printf '%s\n' "$out"
        else
          printf '%s\n' "localhost"
        fi
        EOF
            chmod +x "$out/bin/hostname"
          else
            ln -s "$bin" "$out/bin/$bn"
          fi
        done
      '';

  # Patch home-manager CLI for Termux: safe hostname fallback without failing set -e.
  mkHomeManagerTermux =
    targetPkgs:
    targetPkgs.home-manager.overrideAttrs (old: {
      postFixup = (old.postFixup or "") + ''
        substituteInPlace $out/bin/home-manager \
          --replace-fail \
            'for n in "$USER@$(hostname -f)" "$USER@$(hostname)" "$USER@$(hostname -s)"; do' \
            'local _hm_h _hm_hf _hm_hs; _hm_h="$(hostname 2>/dev/null || echo localhost)"; _hm_hf="$(hostname -f 2>/dev/null || echo "$_hm_h")"; _hm_hs="$(hostname -s 2>/dev/null || echo "$_hm_h")"; for n in "$USER@$_hm_hf" "$USER@$_hm_h" "$USER@$_hm_hs"; do'
      '';
    });

  # Convenience CLI for initializing a Home Manager config on Termux
  # targeting the project's single fixed ISA (armv8.2-a on aarch64, x86-64-v2 on x86_64).
  mkTermuxHomeManagerInit =
    targetPkgs:
    targetPkgs.runCommand "termux-home-manager-init" { } ''
      mkdir -p $out/bin
      cat > $out/bin/termux-home-manager-init << 'EOF'
      #!${targetPkgs.bash}/bin/bash
      set -euo pipefail

      USE_FLAKE=0
      FORCE=0
      NIXPKGS_SRC=""
      HM_SRC=""

      while [ $# -gt 0 ]; do
        case "$1" in
          --flake) USE_FLAKE=1; shift ;;
          --force|-f) FORCE=1; shift ;;
          --nixpkgs) NIXPKGS_SRC="$2"; shift 2 ;;
          --home-manager) HM_SRC="$2"; shift 2 ;;
          -h|--help)
            echo "Usage: termux-home-manager-init [--flake] [--force] [--nixpkgs PATH_OR_URL] [--home-manager PATH_OR_URL]"
            echo ""
            echo "Initializes ~/.config/home-manager/ for prefixed Bionic Nix on Termux (fixed aarch64 ISA: ${androidAarch64GccArch})."
            exit 0
            ;;
          *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
        esac
      done

      CUR_USER="''${USER:-$(id -un)}"
      CUR_HOME="''${HOME:-${termuxPrefix}/home}"
      CFG_HOME="''${XDG_CONFIG_HOME:-$CUR_HOME/.config}"
      HM_DIR="$CFG_HOME/home-manager"
      ARCH="$(uname -m)"
      FIXED_GCC_ARCH=""
      case "$ARCH" in
        aarch64|arm64) NIX_SYSTEM="aarch64-linux"; FIXED_GCC_ARCH="${androidAarch64GccArch}" ;;
        armv7l)        NIX_SYSTEM="armv7l-linux" ;;
        x86_64)        NIX_SYSTEM="x86_64-linux";  FIXED_GCC_ARCH="x86-64-v2" ;;
        i686)          NIX_SYSTEM="i686-linux" ;;
        *)             NIX_SYSTEM="''${ARCH}-linux" ;;
      esac

      mkdir -p "$HM_DIR"

      if [ -e "$HM_DIR/home.nix" ] && [ "$FORCE" -ne 1 ]; then
        echo "Existing $HM_DIR/home.nix found (pass --force to overwrite)."
      else
        cat > "$HM_DIR/home.nix" << HOMENIX
      { pkgs, ... }:
      {
        imports = [
          ${confDir}/home-manager-termux.nix
        ];

        home.username = "$CUR_USER";
        home.homeDirectory = "$CUR_HOME";
        home.stateVersion = "26.05";

        programs.home-manager.enable = true;

        programs.bash = {
          enable = true;
          shellAliases = {
            ll = "ls -la";
          };
        };

        home.packages = [
          # Add packages or custom scripts here, e.g.:
          # (pkgs.writeShellScriptBin "hello-termux" "echo Hello from Home Manager on Termux!")
        ];
      }
      HOMENIX
        echo "Wrote $HM_DIR/home.nix"
      fi

      if [ "$USE_FLAKE" -eq 1 ]; then
        NIXPKGS_URL="''${NIXPKGS_SRC:-github:NixOS/nixpkgs/nixpkgs-unstable}"
        HM_URL="''${HM_SRC:-github:nix-community/home-manager}"
        if [ -n "$FIXED_GCC_ARCH" ]; then
          LOCAL_SYSTEM_EXPR="{ system = \"$NIX_SYSTEM\"; gcc.arch = \"$FIXED_GCC_ARCH\"; }"
        else
          LOCAL_SYSTEM_EXPR="\"$NIX_SYSTEM\""
        fi
        if [ -e "$HM_DIR/flake.nix" ] && [ "$FORCE" -ne 1 ]; then
          echo "Existing $HM_DIR/flake.nix found (pass --force to overwrite)."
        else
          cat > "$HM_DIR/flake.nix" << FLAKENIX
      {
        description = "Termux Home Manager configuration";

        inputs = {
          nixpkgs.url = "$NIXPKGS_URL";
          home-manager = {
            url = "$HM_URL";
            inputs.nixpkgs.follows = "nixpkgs";
          };
        };

        outputs =
          { nixpkgs, home-manager, ... }:
          let
            localSystem = $LOCAL_SYSTEM_EXPR;
            pkgs = import nixpkgs {
              inherit localSystem;
            };
          in
          {
            homeConfigurations."$CUR_USER" = home-manager.lib.homeManagerConfiguration {
              inherit pkgs;
              modules = [ ./home.nix ];
            };
          };
      }
      FLAKENIX
          echo "Wrote $HM_DIR/flake.nix (localSystem: $LOCAL_SYSTEM_EXPR)"
        fi
        echo ""
        echo "Next step (flake mode):"
        echo "  home-manager switch --flake $HM_DIR#$CUR_USER"
      else
        echo ""
        echo "Next step (channel / NIX_PATH mode):"
        echo "  home-manager switch"
      fi
      EOF
      chmod +x $out/bin/termux-home-manager-init
    '';

  makeStage2Installer =
    {
      archCfg,
      androidSdkVersion ? "35",
      androidNdkVersion ? "27",
      useAndroidPrebuilt ? true,
    }:
    let
      inherit (archCfg) name gccArch systemFeatures;
      variantTag = "${name}-bionic" + lib.optionalString (gccArch != null) "-${gccArch}";
      extraSystemFeaturesStr = lib.concatStringsSep " " systemFeatures;

      targetPkgs = platforms.mkTermuxPkgs {
        nixpkgs = pkgs.path;
        localSystem = pkgs.stdenv.buildPlatform.system;
        arch = name;
        inherit androidSdkVersion androidNdkVersion useAndroidPrebuilt;
      };

      nixBoot = mkPrefixedNix targetPkgs;
      inetutilsTermux = mkInetutilsTermux targetPkgs;
      homeManagerTermux = mkHomeManagerTermux targetPkgs;
      termuxHomeManagerInit = mkTermuxHomeManagerInit targetPkgs;

      # dramforever's exact stdenv stage walk via __bootPackages.stdenv:
      # Including every stdenv stage ensures that building future packages in the
      # pure Stage-2 store avoids rebuilding the Clang/Bionic bootstrap chain.
      collectStdenvStages =
        curStage:
        [ curStage ]
        ++ (
          if (curStage ? __bootPackages) && !(curStage.__bootPackages.__raw or false) then
            collectStdenvStages curStage.__bootPackages.stdenv
          else
            [ ]
        );

      allStdenvStages = collectStdenvStages targetPkgs.stdenv;

      # Default Nix profile installed at $NIX_STATE_DIR/profiles/default
      defaultProfile = targetPkgs.buildEnv {
        name = "nix-termux-default-profile";
        paths = [
          nixBoot
          homeManagerTermux
          termuxHomeManagerInit
          targetPkgs.bashInteractive
          targetPkgs.coreutils
          targetPkgs.findutils
          targetPkgs.gnugrep
          targetPkgs.gnused
          targetPkgs.gawk
          targetPkgs.gnutar
          targetPkgs.gzip
          targetPkgs.xz
          targetPkgs.bzip2
          targetPkgs.diffutils
          targetPkgs.patch
          targetPkgs.curl
          targetPkgs.git
          targetPkgs.cacert
          targetPkgs.jq
          targetPkgs.gettext
          targetPkgs.ncurses
          targetPkgs.less
          targetPkgs.nano
          targetPkgs.which
          targetPkgs.file
          targetPkgs.patchelf
          targetPkgs.perl
          targetPkgs.lndir
          inetutilsTermux
          targetPkgs.nixos-option
        ];
        ignoreCollisions = true;
      };

      nixClosure = pkgs.closureInfo {
        rootPaths = [
          defaultProfile
          targetPkgs.stdenvNoCC
          homeManagerTermux.src
        ]
        ++ allStdenvStages;
      };

      installerScript = pkgs.writeScript "install.sh" ''
        #!/bin/sh
        set -eu

        TERMUX_PREFIX="${termuxPrefix}"
        NIX_PREFIX="${nixPrefix}"
        STORE_DIR="${storeDir}"
        STATE_DIR="${stateDir}"
        LOG_DIR="${logDir}"
        CONF_DIR="${confDir}"
        EXPECTED_ARCH="${name}"
        TARGET_GCC_ARCH="${if gccArch != null then gccArch else "default"}"
        EXTRA_SYSTEM_FEATURES="${extraSystemFeaturesStr}"
        NIX_STORE_BIN="${nixBoot}/bin/nix-store"
        DEFAULT_PROFILE="${defaultProfile}"
        CA_CERT_FILE="${targetPkgs.cacert}/etc/ssl/certs/ca-bundle.crt"

        AUTO_YES=0
        while [ $# -gt 0 ]; do
          case "$1" in
            -y|--yes) AUTO_YES=1; shift ;;
            *) shift ;;
          esac
        done

        echo "======================================"
        echo "Nix + Home Manager Installer for Termux ($EXPECTED_ARCH, bionic, isa=$TARGET_GCC_ARCH)"
        echo "======================================"
        echo ""
        echo "Target prefix:   $NIX_PREFIX"
        echo "Store directory: $STORE_DIR"
        echo "State directory: $STATE_DIR"
        echo "Log directory:   $LOG_DIR"
        echo "Config dir:      $CONF_DIR"
        echo ""

        ARCH=$(uname -m)
        if [ "$ARCH" != "$EXPECTED_ARCH" ]; then
          echo "ERROR: This installer is for $EXPECTED_ARCH only. Detected: $ARCH" >&2
          exit 1
        fi

        if [ ! -e /system/bin/linker64 ] && [ ! -e /system/bin/linker ]; then
          echo "WARNING: Android Bionic dynamic linker (/system/bin/linker64) not found."
          echo "This Bionic build is intended to run natively on Android/Termux."
        fi

        if [ ! -d "$TERMUX_PREFIX" ]; then
          echo "WARNING: $TERMUX_PREFIX not found. Are you running this in Termux?"
          if [ "$AUTO_YES" -ne 1 ] && [ -t 0 ]; then
            echo "Press Ctrl+C to cancel, or Enter to continue anyway..."
            read -r _
          fi
        fi

        CUR_USER="''${USER:-$(id -un 2>/dev/null || echo termux)}"
        CUR_HOME="''${HOME:-$TERMUX_PREFIX/home}"

        echo "Creating directories..."
        if [ -d "$STORE_DIR" ]; then
          echo "Existing store found. Removing old installation..."
          chmod -R u+w "$STORE_DIR" 2>/dev/null || true
          rm -rf "$STORE_DIR"
        fi

        mkdir -p "$STORE_DIR"
        mkdir -p "$STATE_DIR/db"
        mkdir -p "$STATE_DIR/gcroots/per-user/$CUR_USER"
        mkdir -p "$STATE_DIR/profiles/per-user/$CUR_USER"
        mkdir -p "$STATE_DIR/temproots"
        mkdir -p "$LOG_DIR/drvs"
        mkdir -p "$CONF_DIR"
        mkdir -p "$NIX_PREFIX/tmp"
        mkdir -p "$CUR_HOME"

        echo "Copying pure Stage-2 store paths..."
        cp -a ./store/. "$STORE_DIR/"

        echo "Writing nix.conf..."
        cat > "$CONF_DIR/nix.conf" << EOF
        # Nix configuration for Termux ($EXPECTED_ARCH, bionic, isa=$TARGET_GCC_ARCH)
        build-users-group =
        sandbox = false
        experimental-features = nix-command flakes
        max-jobs = auto
        cores = 0
        substituters =
        trusted-public-keys =
        keep-build-log = true
        keep-failed = false
        auto-optimise-store = false
        ssl-cert-file = $CA_CERT_FILE
        EOF
        if [ -n "$EXTRA_SYSTEM_FEATURES" ]; then
          printf 'extra-system-features = %s\n' "$EXTRA_SYSTEM_FEATURES" >> "$CONF_DIR/nix.conf"
        fi

        echo "Installing environment & Home Manager support files..."
        cp ./termux-nix-env.sh "$CONF_DIR/termux-nix-env.sh"
        chmod 644 "$CONF_DIR/termux-nix-env.sh"
        cp ./home-manager-termux.nix "$CONF_DIR/home-manager-termux.nix"
        chmod 644 "$CONF_DIR/home-manager-termux.nix"

        echo "Initializing Nix database..."
        export NIX_STORE_DIR="$STORE_DIR"
        export NIX_STATE_DIR="$STATE_DIR"
        export NIX_CONF_DIR="$CONF_DIR"
        export NIX_LOG_DIR="$LOG_DIR"
        export TMPDIR="''${TMPDIR:-$NIX_PREFIX/tmp}"

        if [ ! -x "$NIX_STORE_BIN" ]; then
          echo "ERROR: nix-store binary not found or not executable at $NIX_STORE_BIN" >&2
          exit 1
        fi
        if [ ! -f ./registration ]; then
          echo "ERROR: registration file missing from installer tarball" >&2
          exit 1
        fi

        "$NIX_STORE_BIN" --load-db < ./registration
        echo "Database initialized successfully."

        echo "Setting up default profile..."
        ln -sfn "$DEFAULT_PROFILE" "$STATE_DIR/profiles/default-1-link"
        ln -sfn "default-1-link" "$STATE_DIR/profiles/default"

        if [ ! -e "$CUR_HOME/.nix-profile" ] && [ ! -L "$CUR_HOME/.nix-profile" ]; then
          ln -s "$STATE_DIR/profiles/per-user/$CUR_USER/profile" "$CUR_HOME/.nix-profile"
        fi

        echo ""
        echo "Installation complete!"
        echo ""
        echo "Load the Nix environment (add to ~/.bashrc or ~/.zshrc):"
        echo "  . $CONF_DIR/termux-nix-env.sh"
        echo ""
        echo "Then initialize Home Manager:"
        echo "  termux-home-manager-init"
        echo "  home-manager switch"
        echo ""
      '';

      envScript = pkgs.writeText "termux-nix-env.sh" (builtins.readFile ./termux-nix-env.sh);
      hmTermuxModule = pkgs.writeText "home-manager-termux.nix" (
        builtins.readFile ./home-manager/termux.nix
      );

      # Enforce dramforever's pure Stage-2 invariant: installer tarballs MUST be
      # built with builtins.storeDir == /data/data/com.termux/files/nix/store
      # (zero patchelf / string-replacement hacks).
      installer =
        assert
          builtins.storeDir == storeDir
          || throw ''
            Pure Stage-2 bootstrap requires builtins.storeDir == "${storeDir}",
            but current builtins.storeDir is "${builtins.storeDir}".

            Build Stage 2 using Stage-1 Nix or `./scripts/build-stage2.sh` / `./build.sh`:
              nix-build --store 'local?root=/path/to/stage2&store=${storeDir}' bootstrap.nix -A installer.${name}
          '';
        pkgs.stdenv.mkDerivation {
          name = "nix-termux-installer-${variantTag}";
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
            cp ${envScript} termux-nix-env.sh
            cp ${hmTermuxModule} home-manager-termux.nix

            cat > README.txt << EOF
            Nix + Home Manager Pure Stage-2 Installer for Termux (${variantTag})
            ======================================================================

            Target: ${archCfg.system} (${archCfg.bionicConfig})
            Libc:   bionic (Android native /system/bin/linker64)
            ISA:    ${if gccArch != null then gccArch else "default"} (fixed project target)
            Store:  ${storeDir}
            State:  ${stateDir}
            Log:    ${logDir}
            Config: ${confDir}

            Installation:
              1. Extract this tarball
              2. Run: sh ./install.sh
              3. Source environment: . ${confDir}/termux-nix-env.sh
              4. Set up Home Manager:
                   termux-home-manager-init
                   home-manager switch
            EOF

            cd $out
            echo "Creating tarball..."
            tar -czf nix-termux-${variantTag}.tar.gz tarball/
            ln -s nix-termux-${variantTag}.tar.gz tarball.tar.gz
            if [ "nix-termux-${variantTag}.tar.gz" != "nix-termux-${name}.tar.gz" ]; then
              ln -s nix-termux-${variantTag}.tar.gz nix-termux-${name}.tar.gz
            fi
            ls -lh nix-termux-${variantTag}.tar.gz
          '';
        };
    in
    {
      inherit
        installer
        nixBoot
        homeManagerTermux
        termuxHomeManagerInit
        defaultProfile
        nixClosure
        allStdenvStages
        targetPkgs
        storeDir
        stateDir
        logDir
        confDir
        ;
    };

  archInstallers = lib.mapAttrs (
    _name: archCfg: (makeStage2Installer { inherit archCfg; }).installer
  ) supportedArchs;
in
{
  # Stage 1: Host Nix driver compiled for /data/data/com.termux/files/nix/store
  inherit nixStage1 mkPrefixedNix;

  # Stage 2: Pure Bionic Termux installers (require builtins.storeDir == /data/data/com.termux/files/nix/store)
  installer = archInstallers;

  # Helpers also reused by tests/vm-test.nix
  inherit
    mkInetutilsTermux
    mkHomeManagerTermux
    mkTermuxHomeManagerInit
    makeStage2Installer
    supportedArchs
    androidAarch64GccArch
    platforms
    termuxPrefix
    nixPrefix
    storeDir
    stateDir
    logDir
    confDir
    ;

  default = archInstallers.aarch64;
}
