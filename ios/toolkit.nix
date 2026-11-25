{ pkgs }:

pkgs.runCommand "nix-ios-toolkit"
  {
    nativeBuildInputs = with pkgs; [
      coreutils
      gnutar
      gzip
    ];
  }
  ''
    mkdir -p $out
    stage="$(mktemp -d)"
    copydir="$stage/nix-ios-toolkit"
    mkdir -p "$copydir"

    cp ${./install-nix-ios.sh} "$copydir/install-nix-ios.sh"
    cp ${./install-payload.sh} "$copydir/install-payload.sh"
    cp ${./sign-store.sh} "$copydir/sign-store.sh"
    cp ${./validate-payload.sh} "$copydir/validate-payload.sh"
    cp ${./ios-nix-env.sh} "$copydir/ios-nix-env.sh"
    cp ${./nix.conf.template} "$copydir/nix.conf.template"
    cp ${./README.md} "$copydir/README.md"
    chmod +x \
      "$copydir/install-nix-ios.sh" \
      "$copydir/install-payload.sh" \
      "$copydir/sign-store.sh" \
      "$copydir/validate-payload.sh"

    tar -czf "$out/nix-ios-toolkit.tar.gz" -C "$stage" nix-ios-toolkit
    (
      cd "$out"
      sha256sum nix-ios-toolkit.tar.gz > checksums.txt
    )
  ''
