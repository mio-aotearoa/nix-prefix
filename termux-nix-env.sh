#!/bin/sh
# Termux environment setup for prefixed Nix + Home Manager
# Source this from ~/.bashrc, ~/.zshrc, or ~/.profile:
#   . /data/data/com.termux/files/nix/etc/nix/termux-nix-env.sh

export TERMUX_PREFIX="/data/data/com.termux/files"
export NIX_PREFIX="$TERMUX_PREFIX/nix"
export NIX_STORE_DIR="$NIX_PREFIX/store"
export NIX_STATE_DIR="$NIX_PREFIX/var/nix"
export NIX_CONF_DIR="$NIX_PREFIX/etc/nix"
export NIX_LOG_DIR="$NIX_PREFIX/var/log/nix"

# Android has no global /tmp; ensure TMPDIR points to a writable directory
if [ -z "${TMPDIR:-}" ] || [ ! -d "${TMPDIR:-}" ]; then
    if [ -d "$TERMUX_PREFIX/usr/tmp" ] && [ -w "$TERMUX_PREFIX/usr/tmp" ]; then
        export TMPDIR="$TERMUX_PREFIX/usr/tmp"
    else
        mkdir -p "$NIX_PREFIX/tmp" 2>/dev/null || true
        export TMPDIR="$NIX_PREFIX/tmp"
    fi
fi

# Ensure USER is set (required by home-manager and nix profiles)
if [ -z "${USER:-}" ]; then
    USER="$(id -un 2>/dev/null || echo termux)"
    export USER
fi

# SSL certificates from bundled cacert
if [ -d "$NIX_STORE_DIR" ]; then
    _nix_cacert=$(find "$NIX_STORE_DIR" -maxdepth 1 -name '*-nss-cacert-*' -type d 2>/dev/null | head -n 1)
    if [ -n "$_nix_cacert" ] && [ -f "$_nix_cacert/etc/ssl/certs/ca-bundle.crt" ]; then
        export NIX_SSL_CERT_FILE="$_nix_cacert/etc/ssl/certs/ca-bundle.crt"
        export SSL_CERT_FILE="$NIX_SSL_CERT_FILE"
    fi
    unset _nix_cacert

    # Terminfo for prefixed ncurses
    _nix_ncurses=$(find "$NIX_STORE_DIR" -maxdepth 1 -name '*-ncurses-*' -type d 2>/dev/null | head -n 1)
    if [ -n "$_nix_ncurses" ] && [ -d "$_nix_ncurses/share/terminfo" ]; then
        case ":${TERMINFO_DIRS:-}:" in
            *":$_nix_ncurses/share/terminfo:"*) ;;
            *) export TERMINFO_DIRS="$_nix_ncurses/share/terminfo${TERMINFO_DIRS:+:$TERMINFO_DIRS}" ;;
        esac
    fi
    unset _nix_ncurses

    # Default home-manager source path for NIX_PATH if not already present
    _nix_hm_src=$(find "$NIX_STORE_DIR" -maxdepth 1 -name '*-home-manager-source' -type d 2>/dev/null | head -n 1)
    if [ -n "$_nix_hm_src" ]; then
        case ":${NIX_PATH:-}:" in
            *"home-manager="*) ;;
            *) export NIX_PATH="home-manager=$_nix_hm_src${NIX_PATH:+:$NIX_PATH}" ;;
        esac
    fi
    unset _nix_hm_src
fi

# Put Home Manager / user Nix profiles ahead of the default bootstrap profile
_nix_xdg_profile="${XDG_STATE_HOME:-$HOME/.local/state}/nix/profile/bin"
_nix_user_profile="$HOME/.nix-profile/bin"
_nix_default_profile="$NIX_STATE_DIR/profiles/default/bin"

for _p in "$_nix_default_profile" "$_nix_user_profile" "$_nix_xdg_profile"; do
    case ":$PATH:" in
        *":$_p:"*) ;;
        *) PATH="$_p:$PATH" ;;
    esac
done
export PATH
unset _nix_xdg_profile _nix_user_profile _nix_default_profile _p

# Source Home Manager session variables if installed
if [ -f "$HOME/.nix-profile/etc/profile.d/hm-session-vars.sh" ]; then
    . "$HOME/.nix-profile/etc/profile.d/hm-session-vars.sh"
elif [ -f "${XDG_STATE_HOME:-$HOME/.local/state}/nix/profile/etc/profile.d/hm-session-vars.sh" ]; then
    . "${XDG_STATE_HOME:-$HOME/.local/state}/nix/profile/etc/profile.d/hm-session-vars.sh"
fi

# Optional manpath
export MANPATH="$NIX_STATE_DIR/profiles/default/share/man${MANPATH:+:$MANPATH}"

# Convenience aliases (bash/zsh)
if [ -n "${BASH_VERSION:-}${ZSH_VERSION:-}" ]; then
    alias nix-update-profile='nix-env -u "*"'
    alias nix-gc='nix-collect-garbage'
    alias nix-gc-old='nix-collect-garbage --delete-old'
    alias nix-list='nix-env -q'
    alias nix-search='nix-env -qaP'
fi
