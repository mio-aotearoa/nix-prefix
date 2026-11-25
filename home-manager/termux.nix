# Reusable Home Manager module for prefixed Nix on Termux (Android)
#
# Import this module in your home.nix or flake homeConfiguration:
#   imports = [ /data/data/com.termux/files/nix/etc/nix/home-manager-termux.nix ];
# or via flake input:
#   imports = [ nix-prefix.homeManagerModules.termux ];

{
  config,
  lib,
  pkgs,
  ...
}:

let
  termuxPrefix = "/data/data/com.termux/files";
  nixPrefix = "${termuxPrefix}/nix";
  nixStoreDir = "${nixPrefix}/store";
  nixStateDir = "${nixPrefix}/var/nix";
  nixConfDir = "${nixPrefix}/etc/nix";
  nixLogDir = "${nixPrefix}/var/log/nix";
  termuxTmpDir = "${termuxPrefix}/usr/tmp";
  nixEnvScript = "${nixConfDir}/termux-nix-env.sh";

  shellEnvSnippet = ''
    if [ -f "${nixEnvScript}" ]; then
      . "${nixEnvScript}"
    fi
  '';
in
{
  config = {
    home.homeDirectory = lib.mkDefault "${termuxPrefix}/home";

    # Android/Termux has no systemd, no desktop MIME database, and building
    # manpage docs/man-db caches pulls in heavy docbook/groff toolchains.
    manual.manpages.enable = lib.mkDefault false;
    manual.html.enable = lib.mkDefault false;
    manual.json.enable = lib.mkDefault false;
    programs.man.enable = lib.mkDefault false;
    xdg.mime.enable = lib.mkDefault false;
    systemd.user.startServices = lib.mkDefault false;
    systemd.user.systemctlPath = lib.mkDefault "/bin/false";
    news.display = lib.mkDefault "silent";

    # On Android Bionic (!isGnu), Home Manager's i18n.glibcLocales module still
    # evaluates on isLinux; provide an empty non-glibc stub so Bionic doesn't pull glibc.
    i18n.glibcLocales = lib.mkIf (!pkgs.stdenv.hostPlatform.isGnu) (
      lib.mkDefault (pkgs.runCommand "bionic-no-glibc-locales" { } "mkdir -p $out" // { version = "0"; })
    );

    # Do not let Home Manager overwrite the prefixed nix.conf by default
    nix.enable = lib.mkDefault false;

    # Preserve prefixed Nix environment and Android TMPDIR across shells
    home.sessionVariables = {
      NIX_PREFIX = lib.mkDefault nixPrefix;
      NIX_STORE_DIR = lib.mkDefault nixStoreDir;
      NIX_STATE_DIR = lib.mkDefault nixStateDir;
      NIX_CONF_DIR = lib.mkDefault nixConfDir;
      NIX_LOG_DIR = lib.mkDefault nixLogDir;
      TMPDIR = lib.mkDefault termuxTmpDir;
    };

    # Keep default Nix profile and Termux tools accessible
    home.sessionPath = lib.mkAfter [
      "${nixStateDir}/profiles/default/bin"
      "${termuxPrefix}/usr/bin"
    ];

    # Automatically load the prefixed Nix env in HM-managed shells
    programs.bash.initExtra = lib.mkIf config.programs.bash.enable (lib.mkBefore shellEnvSnippet);
    programs.zsh.initExtra = lib.mkIf config.programs.zsh.enable (lib.mkBefore shellEnvSnippet);
  };
}
