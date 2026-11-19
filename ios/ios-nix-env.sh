#!/bin/sh
# Environment setup for Nix on rootless jailbroken iOS
# Source from ~/.profile / ~/.zshrc / ~/.bashrc after install:
#   source /var/jb/nix/etc/ios-nix-env.sh

# Nix paths (locked layout under /var/jb — not /nix on SSV root)
export NIX_PREFIX="/var/jb/nix"
export NIX_STORE_DIR="$NIX_PREFIX/store"
export NIX_STATE_DIR="$NIX_PREFIX/var"
export NIX_CONF_DIR="$NIX_PREFIX/etc"

# SSL certificates (first cacert store path, if present)
if [ -d "$NIX_STORE_DIR" ]; then
  _cacert=$(ls "$NIX_STORE_DIR" 2>/dev/null | grep cacert | head -n 1)
  if [ -n "$_cacert" ] && [ -f "$NIX_STORE_DIR/$_cacert/etc/ssl/certs/ca-bundle.crt" ]; then
    export NIX_SSL_CERT_FILE="$NIX_STORE_DIR/$_cacert/etc/ssl/certs/ca-bundle.crt"
  fi
  unset _cacert
fi

# Default profile on PATH
export PATH="$NIX_STATE_DIR/nix/profiles/default/bin:$PATH"
export MANPATH="$NIX_STATE_DIR/nix/profiles/default/share/man:${MANPATH:-}"

# Convenience aliases (bash/zsh)
if [ -n "${BASH_VERSION:-}${ZSH_VERSION:-}" ]; then
  alias nix-update-profile='nix-env -u "*"'
  alias nix-gc='nix-collect-garbage'
  alias nix-gc-old='nix-collect-garbage --delete-old'
  alias nix-list='nix-env -q'
  alias nix-search='nix-env -qaP'
fi

if [ -z "${NIX_IOS_SETUP_DONE:-}" ]; then
  export NIX_IOS_SETUP_DONE=1
  echo "Nix environment loaded (rootless iOS)"
  echo "Store: $NIX_STORE_DIR"
  if [ ! -e /var/jb ] && [ ! -L /var/jb ]; then
    echo "WARNING: /var/jb missing — is the jailbreak active?"
  fi
  if command -v nix-env >/dev/null 2>&1; then
    echo "Nix version: $(nix-env --version 2>/dev/null || echo unknown)"
  else
    echo "WARNING: Nix binaries not found in PATH — run the installer?"
  fi
fi
