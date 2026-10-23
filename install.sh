#!/usr/bin/env bash
#
# Spotifast installer for Linux (Ubuntu-based distributions).
#
# Installs the official Spotifast AppImage for the current user, adds a desktop
# entry and icon so it appears in the application menu, and installs an updater
# that checks GitHub releases in the background when Spotifast starts.
#
# This is an unofficial community installer. Spotifast itself is developed by
# Carmine Paolino: https://github.com/crmne/spotifast
#
# Usage:
#   ./install.sh                 install the latest release
#   ./install.sh --version X.Y.Z install a specific release
#   ./install.sh --uninstall     remove the app, keep settings
#   ./install.sh --uninstall --purge
#                                remove the app and all Spotifast data
#
# The same script works through a pipe:
#   curl -fsSL https://raw.githubusercontent.com/imdonix/spotifast-install/main/install.sh | bash
#
set -u -o pipefail
: "${HOME:?HOME is not set}"

UPSTREAM_REPO="crmne/spotifast"
INSTALL_DIR="${SPOTIFAST_INSTALL_DIR:-$HOME/.local/opt/spotifast}"
BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
APPS_DIR="$DATA_HOME/applications"
ICON_DIR="$DATA_HOME/icons/hicolor/scalable/apps"
INSTALLER_STATE_DIR="$STATE_HOME/spotifast-install"

# Pinned Spotifast release signing key. Keep this in sync with
# lib/spotifast-update.
PUBKEY_PEM='-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEA5EyHsVUEhMaHlHvZJ64zP/QxzHrcbMM1M8Yo+CAWtVQ=
-----END PUBLIC KEY-----'

VERSION=""
FORCE=0
UNINSTALL=0
PURGE=0
WORKDIR=""

if [ -t 1 ]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_RED=$'\033[31m'
  C_DIM=$'\033[2m'
else
  C_RESET=""
  C_BOLD=""
  C_GREEN=""
  C_YELLOW=""
  C_RED=""
  C_DIM=""
fi

info() { printf '%s==>%s %s\n' "$C_GREEN$C_BOLD" "$C_RESET" "$*"; }
warn() { printf '%swarning:%s %s\n' "$C_YELLOW$C_BOLD" "$C_RESET" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$C_RED$C_BOLD" "$C_RESET" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
${C_BOLD}Spotifast installer for Linux${C_RESET}

Usage:
  install.sh                 install or update to the latest release
  install.sh --version X.Y.Z install a specific release
  install.sh --force         continue even if the glibc check fails
  install.sh --uninstall     remove Spotifast, keep settings and sign-ins
  install.sh --uninstall --purge
                             remove Spotifast and all of its data
  install.sh --help          show this help

Environment:
  SPOTIFAST_INSTALL_DIR      install directory (default: ~/.local/opt/spotifast)
  XDG_BIN_HOME               command directory (default: ~/.local/bin)
  XDG_DATA_HOME              desktop/icon directory (default: ~/.local/share)
  XDG_STATE_HOME             installer state directory (default: ~/.local/state)
  SPOTIFAST_REPO_RAW         raw base for lib/ helpers (forks and testing)
EOF
}

cleanup() {
  if [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; then
    rm -rf "$WORKDIR"
  fi
}
trap cleanup EXIT INT TERM

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --version)
        [ $# -ge 2 ] || die "--version needs a value, for example --version 0.14.1"
        case "$2" in
          -*) die "--version needs a version number, for example 0.14.1" ;;
        esac
        VERSION="${2#v}"
        [ -n "$VERSION" ] || die "--version needs a version number, for example 0.14.1"
        shift
        ;;
      --version=*)
        VERSION="${1#*=}"
        VERSION="${VERSION#v}"
        [ -n "$VERSION" ] || die "--version needs a version number, for example 0.14.1"
        ;;
      --force)
        FORCE=1
        ;;
      --uninstall)
        UNINSTALL=1
        ;;
      --purge)
        PURGE=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown option: $1 (try --help)"
        ;;
    esac
    shift
  done

  if [ "$PURGE" -eq 1 ] && [ "$UNINSTALL" -eq 0 ]; then
    die "--purge can only be used together with --uninstall"
  fi
}

version_ge() {
  # Return success when $1 is greater than or equal to $2.
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n 1)" = "$2" ]
}

check_platform() {
  [ -n "${HOME:-}" ] || die "HOME is not set"

  if [ "$(uname -s)" != "Linux" ]; then
    die "This installer only supports Linux."
  fi

  case "$(uname -m)" in
    x86_64|amd64)
      ARCH="x86_64"
      ;;
    aarch64|arm64)
      ARCH="aarch64"
      ;;
    *)
      die "Unsupported CPU architecture: $(uname -m). Spotifast provides x86_64 and aarch64 Linux builds."
      ;;
  esac

  command -v curl >/dev/null 2>&1 || die "curl is required. Install it with: sudo apt install curl"
  command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required (package coreutils)."
  command -v awk >/dev/null 2>&1 || die "awk is required."
  command -v sort >/dev/null 2>&1 || die "sort is required (package coreutils)."
}

check_glibc() {
  local current
  current="$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{print $2}')"
  [ -n "$current" ] || return 0

  if ! version_ge "$current" "2.39"; then
    warn "Spotifast's Linux builds require glibc 2.39 or newer (Ubuntu 24.04 or newer)."
    warn "This system has glibc $current, so Spotifast will probably not start."
    if [ "$FORCE" -ne 1 ]; then
      die "Install a newer distribution, or rerun with --force to try anyway."
    fi
    warn "Continuing because --force was given."
  fi
}

latest_version() {
  local url
  url="$(curl -fsSL --connect-timeout 15 --max-time 30 -o /dev/null -w '%{url_effective}' \
    "https://github.com/$UPSTREAM_REPO/releases/latest" 2>/dev/null)" || return 1
  url="${url%%\?*}"
  url="${url%/}"

  case "$url" in
    */tag/v[0-9]*)
      printf '%s\n' "${url##*/tag/v}"
      ;;
    */tag/[0-9]*)
      printf '%s\n' "${url##*/tag/}"
      ;;
    *)
      return 1
      ;;
  esac
}

download() {
  local url="$1"
  local dest="$2"

  if [ -t 2 ]; then
    curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 600 \
      --progress-bar -o "$dest" "$url"
  else
    curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 600 \
      -o "$dest" "$url"
  fi
}

download_quiet() {
  curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 120 -o "$2" "$1"
}

# The launcher, updater, and fallback icon live in lib/ so they can be reviewed
# and edited on their own. When this script is piped from GitHub, they are
# downloaded from the same branch as this installer.
SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
fi
RAW_BASE="${SPOTIFAST_REPO_RAW:-https://raw.githubusercontent.com/imdonix/spotifast-install/main}"

helper_file() {
  local name="$1"
  local dest

  if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/lib/$name" ]; then
    printf '%s\n' "$SCRIPT_DIR/lib/$name"
    return 0
  fi

  if [ -z "$WORKDIR" ]; then
    WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/spotifast-install.XXXXXXXX")" || return 1
  fi
  dest="$WORKDIR/helper-$name"
  curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 120 \
    -o "$dest" "$RAW_BASE/lib/$name" || return 1
  printf '%s\n' "$dest"
}

verify_signature() {
  local dir="$1"

  if ! command -v openssl >/dev/null 2>&1; then
    warn "openssl not found; skipping the Ed25519 signature check (SHA-256 is still verified)."
    return 0
  fi

  case "$(openssl version 2>/dev/null)" in
    "OpenSSL 3."*|"OpenSSL 4."*|"OpenSSL 5."*)
      ;;
    *)
      warn "OpenSSL 3 or newer is needed for the Ed25519 signature check; skipping it (SHA-256 is still verified)."
      return 0
      ;;
  esac

  printf '%s\n' "$PUBKEY_PEM" > "$dir/spotifast-update-key.pem"
  openssl pkeyutl -verify -pubin -inkey "$dir/spotifast-update-key.pem" \
    -rawin -in "$dir/checksums.txt" -sigfile "$dir/checksums.txt.sig" \
    >/dev/null 2>&1
}

desktop_quote() {
  # Escape the characters the Desktop Entry spec reserves inside quoted Exec
  # arguments. The sed expressions contain literal $ and ` characters.
  # shellcheck disable=SC2016
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/`/\\`/g' -e 's/\$/\\$/g' -e 's/%/%%/g'
}

install_appimage() {
  local asset base expected actual new_mode new_version out

  if [ -z "$VERSION" ]; then
    info "Finding the latest Spotifast release..."
    VERSION="$(latest_version)" || die "Could not determine the latest release. Check your connection or pass --version X.Y.Z."
  fi

  asset="spotifast-${VERSION}-${ARCH}.AppImage"
  base="https://github.com/$UPSTREAM_REPO/releases/download/v${VERSION}"

  mkdir -p "$INSTALL_DIR" || die "Could not create $INSTALL_DIR"
  WORKDIR="$(mktemp -d "$INSTALL_DIR/.install.XXXXXXXX")" || die "Could not create a temporary directory in $INSTALL_DIR"

  info "Downloading Spotifast ${C_BOLD}$VERSION${C_RESET} for $ARCH..."
  download "$base/$asset" "$WORKDIR/$asset" || die "Download failed. Check your connection and try again."

  info "Verifying the release..."
  download_quiet "$base/checksums.txt" "$WORKDIR/checksums.txt" || die "Could not download checksums.txt."
  download_quiet "$base/checksums.txt.sig" "$WORKDIR/checksums.txt.sig" || die "Could not download checksums.txt.sig."

  verify_signature "$WORKDIR" || die "The release signature is not valid. Aborting."

  expected="$(awk -v file="$asset" '{ name = $2; sub(/^\*/, "", name); if (name == file) { print $1; exit } }' "$WORKDIR/checksums.txt")"
  [ -n "$expected" ] || die "The release does not publish a checksum for $asset (AppImage checksums are available from v0.14.0 onward)."
  actual="$(sha256sum "$WORKDIR/$asset" | awk '{print $1}')"
  [ "$expected" = "$actual" ] || die "The downloaded AppImage does not match its published checksum. Aborting."

  # Check that the AppImage can run here before replacing a working install.
  chmod 755 "$WORKDIR/$asset"
  new_mode="direct"
  if ! out="$("$WORKDIR/$asset" --version 2>/dev/null)"; then
    if out="$("$WORKDIR/$asset" --appimage-extract-and-run --version 2>/dev/null)"; then
      new_mode="extract"
    else
      die "The downloaded AppImage cannot run on this system. FUSE is optional, but the AppImage runtime must work."
    fi
  fi
  new_version="$(printf '%s\n' "$out" | awk 'NR == 1 { print $NF }')"
  [ "$new_version" = "$VERSION" ] ||
    die "The downloaded AppImage reports version '$new_version', expected '$VERSION'."

  mv -f "$WORKDIR/$asset" "$INSTALL_DIR/Spotifast.AppImage" || die "Could not install the AppImage."
  chmod 755 "$INSTALL_DIR/Spotifast.AppImage"
  printf '%s\n' "$new_mode" > "$INSTALL_DIR/run-mode"
  printf '%s\n' "$VERSION" > "$INSTALL_DIR/VERSION"

  APPIMAGE="$INSTALL_DIR/Spotifast.AppImage"
}

install_scripts() {
  local launcher_src updater_src

  mkdir -p "$INSTALL_DIR" "$BIN_DIR" || die "Could not create installation directories."

  launcher_src="$(helper_file spotifast-launcher)" ||
    die "Could not find lib/spotifast-launcher (network problem?)."
  updater_src="$(helper_file spotifast-update)" ||
    die "Could not find lib/spotifast-update (network problem?)."

  cp "$launcher_src" "$INSTALL_DIR/spotifast-launcher" ||
    die "Could not install the launcher."
  cp "$updater_src" "$INSTALL_DIR/spotifast-update" ||
    die "Could not install the updater."
  chmod 755 "$INSTALL_DIR/spotifast-launcher" "$INSTALL_DIR/spotifast-update" ||
    die "Could not make the launcher and updater executable."

  if [ -e "$BIN_DIR/spotifast" ] && [ ! -L "$BIN_DIR/spotifast" ]; then
    warn "$BIN_DIR/spotifast already exists and is not a symlink; leaving it alone."
    warn "Use $INSTALL_DIR/spotifast-launcher instead."
  else
    ln -sfn "$INSTALL_DIR/spotifast-launcher" "$BIN_DIR/spotifast" ||
      die "Could not create $BIN_DIR/spotifast"
  fi

  if [ -e "$BIN_DIR/spotifast-update" ] && [ ! -L "$BIN_DIR/spotifast-update" ]; then
    warn "$BIN_DIR/spotifast-update already exists and is not a symlink; leaving it alone."
  else
    ln -sfn "$INSTALL_DIR/spotifast-update" "$BIN_DIR/spotifast-update" ||
      die "Could not create $BIN_DIR/spotifast-update"
  fi
}

install_desktop() {
  local icon_source="" launcher update_cmd

  mkdir -p "$APPS_DIR" "$ICON_DIR" || die "Could not create desktop integration directories."

  if [ -x "$APPIMAGE" ] && [ -n "$WORKDIR" ]; then
    mkdir -p "$WORKDIR/icon" 2>/dev/null || true
    if ( cd "$WORKDIR/icon" && "$APPIMAGE" --appimage-extract spotifast.svg >/dev/null 2>&1 ); then
      icon_source="$WORKDIR/icon/squashfs-root/spotifast.svg"
    fi
  fi

  if [ -z "$icon_source" ]; then
    warn "Could not read the icon from the AppImage; using the bundled icon."
    icon_source="$(helper_file spotifast.svg)" ||
      die "Could not find lib/spotifast.svg (network problem?)."
  fi

  if [ -s "$icon_source" ]; then
    cp "$icon_source" "$ICON_DIR/spotifast.svg" || die "Could not install the icon."
  else
    die "Could not install the Spotifast icon."
  fi
  chmod 644 "$ICON_DIR/spotifast.svg"

  launcher="$(desktop_quote "$INSTALL_DIR/spotifast-launcher")"
  update_cmd="$(desktop_quote "$INSTALL_DIR/spotifast-update")"

  {
    printf '%s\n' \
      '[Desktop Entry]' \
      'Type=Application' \
      'Version=1.0' \
      'Name=Spotifast' \
      'GenericName=Music Player' \
      'Comment=A native Spotify client'
    printf 'Exec="%s" --launch %%u\n' "$launcher"
    printf '%s\n' \
      'Terminal=false' \
      'Categories=AudioVideo;Audio;Player;Music;' \
      'Keywords=spotify;music;player;streaming;spotifast;' \
      'Icon=spotifast' \
      'StartupNotify=true' \
      'StartupWMClass=spotifast' \
      'MimeType=x-scheme-handler/spotify;' \
      'Actions=CheckForUpdates;' \
      '' \
      '[Desktop Action CheckForUpdates]' \
      'Name=Check for Updates'
    printf 'Exec="%s" --gui\n' "$update_cmd"
  } > "$APPS_DIR/spotifast.desktop" || die "Could not write the desktop entry."
  chmod 644 "$APPS_DIR/spotifast.desktop"

  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
  fi
  if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f -t "$DATA_HOME/icons/hicolor" >/dev/null 2>&1 || true
  fi

  if command -v xdg-mime >/dev/null 2>&1; then
    local existing
    existing="$(xdg-mime query default x-scheme-handler/spotify 2>/dev/null || true)"
    if [ -z "$existing" ] || [ "$existing" = "spotifast.desktop" ]; then
      xdg-mime default spotifast.desktop x-scheme-handler/spotify >/dev/null 2>&1 || true
    fi
  fi
}

print_summary() {
  local version
  version="$(cat "$INSTALL_DIR/VERSION" 2>/dev/null || printf '%s' "$VERSION")"

  printf '\n'
  info "Spotifast $version is installed."
  printf '\n'
  printf '  Application   %s\n' "$APPIMAGE"
  printf '  Command       %s\n' "$BIN_DIR/spotifast"
  printf '  Updates       automatic once a day on launch, or: spotifast-update --gui\n'
  printf '  Update log    %s\n' "$INSTALLER_STATE_DIR/update.log"
  printf '\n'
  printf 'Open %sSpotifast%s from your application menu. If it is not there yet,\n' "$C_BOLD" "$C_RESET"
  printf 'log out and back in, or run: update-desktop-database %s\n' "$APPS_DIR"

  case ":$PATH:" in
    *":$BIN_DIR:"*)
      ;;
    *)
      printf '\n'
      warn "$BIN_DIR is not on your PATH. The app menu still works."
      warn "To use the 'spotifast' and 'spotifast-update' commands, add this to your shell profile:"
      # shellcheck disable=SC2016
      printf '  export PATH="%s:$PATH"\n' "$BIN_DIR"
      ;;
  esac

  printf '\n'
  printf '%sSpotify playback requires Spotify Premium.%s\n' "$C_DIM" "$C_RESET"
}

remove_symlink() {
  local link="$1"
  local target="$2"

  if [ -L "$link" ] && [ "$(readlink -f -- "$link" 2>/dev/null || true)" = "$(readlink -f -- "$target" 2>/dev/null || true)" ]; then
    rm -f "$link"
    return 0
  fi
  return 1
}

remove_autostart() {
  local entry="$CONFIG_HOME/autostart/spotifast.desktop"

  if [ -f "$entry" ] && grep -q "spotifast" "$entry" 2>/dev/null; then
    rm -f "$entry"
    info "Removed the login autostart entry."
  fi
}

do_uninstall() {
  info "Removing Spotifast..."

  remove_symlink "$BIN_DIR/spotifast" "$INSTALL_DIR/spotifast-launcher" || true
  remove_symlink "$BIN_DIR/spotifast-update" "$INSTALL_DIR/spotifast-update" || true

  rm -f "$APPS_DIR/spotifast.desktop"
  rm -f "$ICON_DIR/spotifast.svg"
  rm -rf "$INSTALL_DIR"
  rm -rf "$INSTALLER_STATE_DIR"

  remove_autostart

  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true
  fi
  if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f -t "$DATA_HOME/icons/hicolor" >/dev/null 2>&1 || true
  fi

  if [ "$PURGE" -eq 1 ]; then
    rm -rf "$CONFIG_HOME/spotifast" "$STATE_HOME/spotifast" "$CACHE_HOME/spotifast"
    info "Removed Spotifast settings, caches, and local state."
    printf 'Spotify grants in the desktop keyring were not touched. To revoke them,\n'
    printf 'reinstall Spotifast, open Settings, and use Sign out before uninstalling.\n'
  else
    printf '\n'
    printf 'Settings and local state were kept in:\n'
    printf '  %s\n' "$CONFIG_HOME/spotifast"
    printf '  %s\n' "$STATE_HOME/spotifast"
    printf '  %s\n' "$CACHE_HOME/spotifast"
    printf 'Run with --uninstall --purge to remove those too.\n'
  fi

  info "Spotifast was uninstalled."
}

main() {
  parse_args "$@"

  if [ "$UNINSTALL" -eq 1 ]; then
    do_uninstall
    return 0
  fi

  check_platform
  check_glibc

  info "Installing Spotifast for the current user..."
  install_appimage
  install_scripts
  install_desktop
  print_summary
}

main "$@"
