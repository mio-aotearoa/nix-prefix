# End-to-end QEMU/KVM VM test for pure dramforever Stage-1 -> Stage-2
# prefixed Nix + Home Manager on Termux (ZERO patchelf / path-replacing hacks).
#
# Verifies inside a real QEMU/KVM VM simulating Termux (/data/data/com.termux/files,
# unprivileged user u0_a100, TMPDIR=/data/data/com.termux/files/usr/tmp):
#   1. Stage-1 Nix (`nixStage1`) compiled natively with:
#        store-dir     = /data/data/com.termux/files/nix/store
#        localstatedir = /data/data/com.termux/files/nix/var   (-> NIX_STATE_DIR=.../var/nix)
#        log-dir       = /data/data/com.termux/files/nix/var/log/nix
#        sysconfdir    = /data/data/com.termux/files/nix/etc   (-> NIX_CONF_DIR=.../etc/nix)
#   2. Pure Stage-2 prefixed store operations (ZERO patchelf!):
#        - `builtins.storeDir == "/data/data/com.termux/files/nix/store"`
#        - Real derivations built natively directly under `/data/data/com.termux/files/nix/store`
#        - `nix-store --verify --check-contents` passes on the genuine prefixed DB
#        - `bootstrap.nix` enforces `builtins.storeDir == "/data/data/com.termux/files/nix/store"`
#          (rejects host `/nix/store` evaluation of Stage-2 `installer` and succeeds when
#          evaluated under Stage-1 Nix!)
#   3. Android Bionic C library + single fixed aarch64 ISA (`armv8.2-a`):
#        - Verifies a real cross-compiled Bionic ELF binary (`bionicHelloAarch64`) has
#          `ARM aarch64`, `PT_INTERP = /system/bin/linker64`, `DT_NEEDED = libc.so` (zero glibc)
#        - Verifies `platforms.nix` fixes `aarch64` to Bionic + `armv8.2-a`
#        - Verifies `home-manager/termux.nix` evaluates cleanly under Bionic (no glibcLocales crash)
#   4. Home Manager for Termux (`home-manager/termux.nix`, `termux-home-manager-init`,
#      Termux-patched `home-manager` CLI with safe `hostname -f`, and real activation as u0_a100
#      into `/data/data/com.termux/files/home` verifying dotfiles, `hm-session-vars.sh`,
#      custom package in `~/.nix-profile/bin`, and generation 1 -> generation 2 switching!).

{
  pkgs,
  nixStage1,
  bionicHelloAarch64,
  termuxBootstrap,
  nixpkgsSrc,
  repoSrc,
}:

let
  hmSrc = pkgs.home-manager.src;
  homeManagerTermux = termuxBootstrap.mkHomeManagerTermux pkgs;
  termuxHomeManagerInit = termuxBootstrap.mkTermuxHomeManagerInit pkgs;

  # Build two real Home Manager activation packages using our Termux module
  # (`home-manager/termux.nix`) to test real Home Manager activation & generation
  # switching as unprivileged Termux user `u0_a100` in `/data/data/com.termux/files/home`.
  mkTestHmGen =
    genTag:
    (import "${hmSrc}/modules" {
      inherit pkgs;
      configuration =
        { pkgs, ... }:
        {
          imports = [ ../home-manager/termux.nix ];

          home.username = "u0_a100";
          home.homeDirectory = "/data/data/com.termux/files/home";
          home.stateVersion = "26.05";

          programs.home-manager.enable = true;

          programs.bash = {
            enable = true;
            shellAliases = {
              ll = "ls -la";
            };
          };

          programs.git = {
            enable = true;
            settings.user = {
              name = "Termux User";
              email = "termux@example.com";
            };
          };

          home.file.".hello-termux".text = "${genTag}\n";
          home.sessionVariables = {
            MY_TERMUX_HM_VAR = "works-in-termux";
          };

          home.packages = [
            (pkgs.writeShellScriptBin "termux-greet" "echo GREET_FROM_HM_PACKAGE")
          ];
        };
    }).activationPackage;

  hmGen1 = mkTestHmGen "generation-1-ok";
  hmGen2 = mkTestHmGen "generation-2-ok";
in
pkgs.testers.runNixOSTest {
  name = "nix-prefix-termux-dramforever-vm";

  nodes.machine =
    { pkgs, ... }:
    {
      virtualisation = {
        memorySize = 4096;
        diskSize = 8192;
        cores = 4;
        writableStore = true;
        additionalPaths = [
          hmGen1
          hmGen2
        ];
      };
      nix = {
        enable = true;
        settings = {
          experimental-features = [
            "nix-command"
            "flakes"
          ];
          trusted-users = [
            "root"
            "u0_a100"
          ];
        };
      };
      environment.systemPackages = [
        pkgs.binutils
        pkgs.file
        pkgs.git
      ];
      users.groups.u0_a100.gid = 10100;
      users.users.u0_a100 = {
        isNormalUser = true;
        uid = 10100;
        group = "u0_a100";
        home = "/data/data/com.termux/files/home";
        createHome = false;
      };
    };

  testScript = ''
    import shlex

    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("nix-daemon.socket")

    # 1. Create Termux directory hierarchy owned by unprivileged u0_a100
    machine.succeed("""
      set -euo pipefail
      TERMUX=/data/data/com.termux/files
      NIX_PREFIX="$TERMUX/nix"
      mkdir -p \
        "$TERMUX/home" \
        "$TERMUX/usr/bin" \
        "$TERMUX/usr/tmp" \
        "$NIX_PREFIX/store" \
        "$NIX_PREFIX/var/nix/db" \
        "$NIX_PREFIX/var/nix/gcroots/per-user/u0_a100" \
        "$NIX_PREFIX/var/nix/profiles/per-user/u0_a100" \
        "$NIX_PREFIX/var/nix/temproots" \
        "$NIX_PREFIX/var/log/nix/drvs" \
        "$NIX_PREFIX/etc/nix" \
        "$NIX_PREFIX/tmp"

      cp ${repoSrc}/termux-nix-env.sh "$NIX_PREFIX/etc/nix/termux-nix-env.sh"
      cp ${repoSrc}/home-manager/termux.nix "$NIX_PREFIX/etc/nix/home-manager-termux.nix"
      chmod 644 "$NIX_PREFIX/etc/nix/termux-nix-env.sh" "$NIX_PREFIX/etc/nix/home-manager-termux.nix"

      cat > "$NIX_PREFIX/etc/nix/nix.conf" << 'EOF'
    build-users-group =
    sandbox = false
    experimental-features = nix-command flakes
    max-jobs = auto
    cores = 0
    substituters =
    trusted-public-keys =
    keep-build-log = true
    auto-optimise-store = false
    extra-system-features = gccarch-x86-64 gccarch-x86-64-v2
    EOF

      ln -sfn "$NIX_PREFIX/var/nix/profiles/per-user/u0_a100/profile" "$TERMUX/home/.nix-profile"
      chown -R 10100:10100 "$TERMUX"
    """)

    def run_as_termux(script: str) -> str:
        cmd = (
            "su -s ${pkgs.bash}/bin/bash u0_a100 -c "
            + shlex.quote(
                "export HOME=/data/data/com.termux/files/home "
                "USER=u0_a100 "
                "PREFIX=/data/data/com.termux/files/usr "
                "TMPDIR=/data/data/com.termux/files/usr/tmp "
                "PATH=${nixStage1}/bin:${homeManagerTermux}/bin:${termuxHomeManagerInit}/bin:${pkgs.coreutils}/bin:${pkgs.gnugrep}/bin:${pkgs.gnused}/bin:${pkgs.findutils}/bin:${pkgs.git}/bin:${pkgs.binutils}/bin:${pkgs.file}/bin:${pkgs.bash}/bin; "
                "set -euo pipefail; "
                + script
            )
        )
        return machine.succeed(cmd)

    # 2. Verify Stage-1 Nix compile-time custom prefix (dramforever Flavor 1)
    #    ZERO env var overrides — verify compiled-in store-dir, state-dir, log-dir, conf-dir!
    out = run_as_termux("""
      unset NIX_STORE_DIR NIX_STATE_DIR NIX_CONF_DIR NIX_LOG_DIR NIX_REMOTE
      echo "STAGE1_VERSION=$(nix --version)"

      STORE_DIR=$(nix eval --raw --expr 'builtins.storeDir')
      echo "COMPILED_STORE_DIR=$STORE_DIR"
      test "$STORE_DIR" = "/data/data/com.termux/files/nix/store"

      # Verify compiled-in sysconfdir reads /data/data/com.termux/files/nix/etc/nix/nix.conf
      nix config show | grep -q '^sandbox = false'
      nix config show | grep -q 'flakes'
      nix config show | grep -q 'gccarch-x86-64-v2'

      # Initialize genuine prefixed Nix DB under /data/data/com.termux/files/nix/var/nix/db
      nix-store --init
      test -f /data/data/com.termux/files/nix/var/nix/db/db.sqlite

      # Build a genuine derivation directly into /data/data/com.termux/files/nix/store (ZERO patchelf!)
      OUT_PATH=$(nix build --no-link --print-out-paths --impure --expr '
        derivation {
          name = "dramforever-stage2-probe";
          system = builtins.currentSystem;
          builder = "${pkgs.bash}/bin/bash";
          args = [ "-c" "echo pure-stage2-ok > $out" ];
        }
      ')
      echo "GENUINE_PREFIX_OUT=$OUT_PATH"
      case "$OUT_PATH" in
        /data/data/com.termux/files/nix/store/*) ;;
        *) echo "ERROR: unexpected store path $OUT_PATH" >&2; exit 1 ;;
      esac
      grep -q "pure-stage2-ok" "$OUT_PATH"

      # Verify DB integrity & NAR hashes in the genuine prefixed store
      nix-store --verify --check-contents

      # Verify dramforever Stage-2 invariant in bootstrap.nix:
      # Evaluating bootstrap.nix with Stage-1 Nix (builtins.storeDir == /data/data/com.termux/files/nix/store)
      # passes the Stage-2 assertion and evaluates a genuine Bionic aarch64 armv8.2-a Stage-2 installer drv!
      STAGE2_DRV=$(nix eval --raw --impure --expr '
        (import ${repoSrc}/bootstrap.nix { nixpkgs = ${nixpkgsSrc}; }).installer.aarch64.drvPath
      ')
      echo "STAGE2_BIONIC_DRV=$STAGE2_DRV"
      case "$STAGE2_DRV" in
        /data/data/com.termux/files/nix/store/*-nix-termux-installer-aarch64-bionic-armv8.2-a.drv) ;;
        *) echo "ERROR: unexpected Stage-2 drv $STAGE2_DRV" >&2; exit 1 ;;
      esac

      # Verify pure Stage-2 invariant rejects /nix/store evaluation!
      if nix eval --store /nix/store --impure --expr '
        (import ${repoSrc}/bootstrap.nix { nixpkgs = ${nixpkgsSrc}; }).installer.aarch64.drvPath
      ' >/dev/null 2>&1; then
        echo "ERROR: bootstrap.nix should reject non-prefixed /nix/store Stage-2 eval!" >&2
        exit 1
      fi
      echo "DRAMFOREVER_STAGE1_STAGE2_OK"
    """)
    print(out)
    assert "DRAMFOREVER_STAGE1_STAGE2_OK" in out, out

    # 3. Verify Android Bionic C library + single fixed aarch64 ISA (armv8.2-a)
    out = run_as_termux("""
      FILE_INFO=$(file "${bionicHelloAarch64}/bin/hello")
      echo "BIONIC_FILE=$FILE_INFO"
      echo "$FILE_INFO" | grep -q "ARM aarch64"
      echo "$FILE_INFO" | grep -q "/system/bin/linker64"
      echo "$FILE_INFO" | grep -q "Android"

      READELF_OUT=$(readelf -l -d "${bionicHelloAarch64}/bin/hello")
      echo "$READELF_OUT" | grep -q "/system/bin/linker64"
      echo "$READELF_OUT" | grep -q "Shared library: \\[libc.so\\]"
      if echo "$READELF_OUT" | grep -q "libc.so.6"; then
        echo "ERROR: glibc leaked into Bionic binary!" >&2
        exit 1
      fi

      # Verify single fixed aarch64 Bionic ISA in platforms.nix
      BIONIC_CHECK=$(nix eval --raw --impure --expr '
        let
          nixpkgs = ${nixpkgsSrc};
          lib = (import nixpkgs { localSystem = builtins.currentSystem; }).lib;
          platforms = import ${repoSrc}/platforms.nix { inherit lib; };
          p = platforms.mkTermuxPkgs { inherit nixpkgs; arch = "aarch64"; };
        in
          assert platforms.androidAarch64GccArch == "armv8.2-a";
          assert p.stdenv.hostPlatform.libc == "bionic";
          assert p.stdenv.hostPlatform.gcc.arch == "armv8.2-a";
          "BIONIC_FIXED_ISA_OK"
      ')
      test "$BIONIC_CHECK" = "BIONIC_FIXED_ISA_OK"

      # Verify Home Manager Termux module evaluates cleanly for Bionic aarch64 (no glibcLocales crash!)
      HM_BIONIC_OK=$(nix eval --raw --impure --expr '
        let
          nixpkgs = ${nixpkgsSrc};
          lib = (import nixpkgs { localSystem = builtins.currentSystem; }).lib;
          platforms = import ${repoSrc}/platforms.nix { inherit lib; };
          bionicPkgs = platforms.mkTermuxPkgs { inherit nixpkgs; arch = "aarch64"; };
          hm = import ${hmSrc}/modules {
            pkgs = bionicPkgs;
            configuration = { ... }: {
              imports = [ ${repoSrc}/home-manager/termux.nix ];
              home.username = "u0_a100";
              home.stateVersion = "26.05";
              home.file.".hello-bionic".text = "hi\n";
            };
          };
        in
          assert hm.config.home.homeDirectory == "/data/data/com.termux/files/home";
          assert hm.config.systemd.user.startServices == false;
          assert builtins.isString hm.activationPackage.drvPath;
          "HM_BIONIC_EVAL_OK"
      ')
      test "$HM_BIONIC_OK" = "HM_BIONIC_EVAL_OK"
      echo "BIONIC_VERIFICATION_OK"
    """)
    print(out)
    assert "BIONIC_VERIFICATION_OK" in out, out

    # 4. Verify Termux Home Manager CLI, termux-home-manager-init, and real Home Manager activation
    #    (Generation 1 -> Generation 2) as unprivileged u0_a100 in /data/data/com.termux/files/home!
    out = run_as_termux("""
      . /data/data/com.termux/files/nix/etc/nix/termux-nix-env.sh
      echo "HM_VERSION=$(home-manager --version)"

      # Test termux-home-manager-init (flake mode with Bionic target + fixed ISA)
      termux-home-manager-init --flake
      test -f "$HOME/.config/home-manager/home.nix"
      test -f "$HOME/.config/home-manager/flake.nix"
      grep -q "/data/data/com.termux/files/nix/etc/nix/home-manager-termux.nix" "$HOME/.config/home-manager/home.nix"
      grep -q 'config = "x86_64-unknown-linux-android"' "$HOME/.config/home-manager/flake.nix"
      grep -q 'gcc.arch = "x86-64-v2"' "$HOME/.config/home-manager/flake.nix"

      # Activate Generation 1 against Termux HOME + prefixed NIX_STATE_DIR
      # (using host nix-daemon socket for the /nix/store-built test generation)
      mkdir -p "$HOME/.local/state/home-manager/gcroots"
      VERBOSE=1 \
      PATH="${pkgs.nix}/bin:$PATH" \
      NIX_REMOTE=unix:///nix/var/nix/daemon-socket/socket \
      NIX_STORE_DIR=/nix/store \
      NIX_STATE_DIR=/data/data/com.termux/files/nix/var/nix \
      NIX_CONF_DIR=/data/data/com.termux/files/nix/etc/nix \
      ${hmGen1}/activate

      # Re-source Termux env to load hm-session-vars.sh and ~/.nix-profile/bin
      . /data/data/com.termux/files/nix/etc/nix/termux-nix-env.sh

      grep -q "generation-1-ok" "$HOME/.hello-termux"
      test -L "$HOME/.bashrc"
      grep -q "Termux User" "$HOME/.config/git/config"
      test "$MY_TERMUX_HM_VAR" = "works-in-termux"
      GREET_OUT=$(termux-greet)
      echo "GREET_OUT=$GREET_OUT"
      test "$GREET_OUT" = "GREET_FROM_HM_PACKAGE"

      # Activate Generation 2 and verify generation switching + home-manager generations CLI
      VERBOSE=1 \
      PATH="${pkgs.nix}/bin:$PATH" \
      NIX_REMOTE=unix:///nix/var/nix/daemon-socket/socket \
      NIX_STORE_DIR=/nix/store \
      NIX_STATE_DIR=/data/data/com.termux/files/nix/var/nix \
      NIX_CONF_DIR=/data/data/com.termux/files/nix/etc/nix \
      ${hmGen2}/activate

      grep -q "generation-2-ok" "$HOME/.hello-termux"
      GEN_LIST=$(PATH="${pkgs.nix}/bin:$PATH" NIX_REMOTE=unix:///nix/var/nix/daemon-socket/socket NIX_STORE_DIR=/nix/store home-manager generations)
      echo "$GEN_LIST"
      GEN_COUNT=$(printf '%s\n' "$GEN_LIST" | wc -l)
      echo "GEN_COUNT=$GEN_COUNT"
      test "$GEN_COUNT" -ge 2
      echo "HM_TERMUX_ACTIVATION_OK"
    """)
    print(out)
    assert "HM_TERMUX_ACTIVATION_OK" in out, out
  '';
}
