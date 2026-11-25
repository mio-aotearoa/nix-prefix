{
  description = "Prefixed Nix stores + Home Manager for Termux (pure dramforever Stage 1 -> Stage 2, Android Bionic + fixed armv8.2-a) and rootless iOS (/var/jb)";

  nixConfig = {
    extra-substituters = [ "https://prefix.cachix.org" ];
    extra-trusted-public-keys = [ "prefix.cachix.org-1:kxW9psUOK2149rGlsQCQ3uD/17460lMtjZxMfOhV9o4=" ];
  };

  inputs = {
    # Package-only unstable channel (faster than nixos-unstable; best for project flakes).
    nixpkgs.url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.zst";
  };

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      platforms = import ./platforms.nix { inherit lib; };
      forSystems = lib.genAttrs [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
        "x86_64-darwin"
      ];
      linuxSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
    in
    {
      # Reusable library helpers for Bionic + fixed Android aarch64 ISA (armv8.2-a)
      lib = {
        inherit (platforms)
          androidAarch64GccArch
          supportedArchs
          mkTargetSystem
          mkTermuxPkgs
          ;
      };

      # Reusable Home Manager module for Termux
      homeManagerModules = {
        termux = import ./home-manager/termux.nix;
        default = self.homeManagerModules.termux;
      };

      packages = forSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          isLinux = pkgs.stdenv.hostPlatform.isLinux;
          termuxBootstrap = import ./bootstrap.nix { inherit pkgs; };
          bionicAarch64Pkgs = platforms.mkTermuxPkgs {
            nixpkgs = nixpkgs.outPath;
            localSystem = system;
            arch = "aarch64";
          };
        in
        {
          # Rootless iOS Stage-1 Nix and pure Stage-2 installer (host: aarch64-darwin)
          ios-nix-stage1 =
            if system == "aarch64-darwin" then
              (import ./ios/bootstrap.nix { inherit pkgs; }).nixStage1
            else
              pkgs.hello;
          ios-installer =
            if system == "aarch64-darwin" then
              (import ./ios/bootstrap.nix { inherit pkgs; }).installer
            else
              pkgs.hello;
        }
        // lib.optionalAttrs isLinux {
          # Flavor 1 (dramforever Stage 1): host Nix compiled for /data/data/com.termux/files/nix/store
          nix-stage1 = termuxBootstrap.nixStage1;

          # Smoke-test Bionic aarch64 armv8.2-a package (verifies Android NDK r27 Clang + Bionic linker64)
          bionic-hello-aarch64 = bionicAarch64Pkgs.hello;

          # Flavor 2 (dramforever Stage 2): pure prefixed Bionic installers (fixed ISA per arch)
          # Must be evaluated with `--store 'local?root=...&store=/data/data/com.termux/files/nix/store'`
          # (via `./build.sh` or `./scripts/build-stage2.sh`).
          termux-installer = termuxBootstrap.default;
          termux-installer-aarch64 = termuxBootstrap.installer.aarch64;
          termux-installer-armv7l = termuxBootstrap.installer.armv7l;
          termux-installer-x86_64 = termuxBootstrap.installer.x86_64;
          termux-installer-i686 = termuxBootstrap.installer.i686;
        }
        // {
          default =
            if system == "aarch64-darwin" then
              self.packages.${system}.ios-nix-stage1
            else if isLinux then
              self.packages.${system}.nix-stage1
            else
              pkgs.hello;
        }
      );

      checks = lib.genAttrs linuxSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          termuxBootstrap = import ./bootstrap.nix { inherit pkgs; };
          bionicAarch64Pkgs = platforms.mkTermuxPkgs {
            nixpkgs = nixpkgs.outPath;
            localSystem = system;
            arch = "aarch64";
          };
        in
        {
          vm-test = import ./tests/vm-test.nix {
            inherit pkgs;
            nixStage1 = termuxBootstrap.nixStage1;
            bionicHelloAarch64 = bionicAarch64Pkgs.hello;
            termuxBootstrap = termuxBootstrap;
            nixpkgsSrc = nixpkgs.outPath;
            repoSrc = self;
          };
        }
      );

      # Expose locked nixpkgs for `nix flake update` / local import.
      legacyPackages = forSystems (system: nixpkgs.legacyPackages.${system});
    };
}
