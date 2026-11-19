{
  description = "Prefixed Nix stores for Termux (aarch64-linux) and rootless iOS (/var/jb)";

  inputs = {
    # Package-only unstable channel (faster than nixos-unstable; best for project flakes).
    nixpkgs.url = "https://channels.nixos.org/nixpkgs-unstable/nixexprs.tar.zst";
  };

  outputs =
    { self, nixpkgs }:
    let
      forSystems = nixpkgs.lib.genAttrs [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
        "x86_64-darwin"
      ];
    in
    {
      packages = forSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          # Rootless iOS installer (host: aarch64-darwin)
          ios-installer =
            if system == "aarch64-darwin" then
              (import ./ios/bootstrap.nix { inherit pkgs; }).installer
            else
              pkgs.hello; # placeholder so other systems still evaluate the flake

          # Termux installer (host: aarch64-linux)
          termux-installer =
            if system == "aarch64-linux" then
              (import ./bootstrap.nix { inherit pkgs; }).installer
            else
              pkgs.hello;

          default =
            if system == "aarch64-darwin" then
              self.packages.${system}.ios-installer
            else if system == "aarch64-linux" then
              self.packages.${system}.termux-installer
            else
              pkgs.hello;
        }
      );

      # Expose locked nixpkgs for `nix flake update` / local import.
      legacyPackages = forSystems (system: nixpkgs.legacyPackages.${system});
    };
}
