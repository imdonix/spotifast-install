#!/usr/bin/env bash
#
# Spotifast installer for Linux and macOS.
#
# Linux: installs the official AppImage for the current user, adds a desktop
# entry and icon, and provides a small launcher for the AppImage runtime.
#
# macOS: installs the official universal Spotifast.app into ~/Applications and
# adds a small CLI wrapper in ~/.local/bin.
#
# Spotifast updates itself from inside the app on both platforms. This script
# only installs, repairs, or removes the app and its desktop integration.
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
OS="$(uname -s)"

# Linux paths.
INSTALL_DIR="${SPOTIFAST_INSTALL_DIR:-$HOME/.local/opt/spotifast}"
if [ "$OS" = "Darwin" ]; then
  BIN_DIR="${SPOTIFAST_BIN_DIR:-$HOME/.local/bin}"
else
  BIN_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
fi
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
APPS_DIR="$DATA_HOME/applications"
ICON_DIR="$DATA_HOME/icons/hicolor/scalable/apps"
INSTALLER_STATE_DIR="$STATE_HOME/spotifast-install"

# macOS paths.
MAC_STATE_DIR="$HOME/Library/Application Support/spotifast-install"
MAC_APP_DIR="${SPOTIFAST_APP_DIR:-}"
if [ -z "$MAC_APP_DIR" ] && [ -f "$MAC_STATE_DIR/app-dir" ]; then
  MAC_APP_DIR="$(cat "$MAC_STATE_DIR/app-dir" 2>/dev/null || true)"
fi
[ -n "$MAC_APP_DIR" ] || MAC_APP_DIR="$HOME/Applications"
MAC_APP_BUNDLE="$MAC_APP_DIR/Spotifast.app"
MAC_LEGACY_LOG_DIR="$HOME/Library/Logs/spotifast-install"
PLIST_BUDDY="${SPOTIFAST_PLIST_BUDDY:-/usr/libexec/PlistBuddy}"
LSREGISTER="${SPOTIFAST_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"

# Pinned Spotifast release signing key.
PUBKEY_PEM='-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEA5EyHsVUEhMaHlHvZJ64zP/QxzHrcbMM1M8Yo+CAWtVQ=
-----END PUBLIC KEY-----'

VERSION=""
FORCE=0
UNINSTALL=0
PURGE=0
WORKDIR=""
APPIMAGE=""
MOUNT_DIR=""
MOUNTED=0
DMG_PATH=""

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
${C_BOLD}Spotifast installer for Linux and macOS${C_RESET}

Usage:
  install.sh                 install or update to the latest release
  install.sh --version X.Y.Z install a specific release
  install.sh --force         continue even if the platform check fails
  install.sh --uninstall     remove Spotifast, keep settings and sign-ins
  install.sh --uninstall --purge
                             remove Spotifast and all of its data
  install.sh --help          show this help

Spotifast updates itself from inside the app. Re-run this script to repair the
desktop integration or install a specific release.

Environment:
  SPOTIFAST_INSTALL_DIR      Linux install directory (default: ~/.local/opt/spotifast)
  SPOTIFAST_APP_DIR          macOS Applications directory (default: ~/Applications)
  SPOTIFAST_BIN_DIR          macOS command directory (default: ~/.local/bin)
  XDG_BIN_HOME               Linux command directory (default: ~/.local/bin)
  XDG_DATA_HOME              Linux desktop/icon directory (default: ~/.local/share)
  XDG_STATE_HOME             Linux state directory (default: ~/.local/state)
EOF
}

cleanup() {
  if [ "${MOUNTED:-0}" -eq 1 ] && [ -n "${MOUNT_DIR:-}" ]; then
    hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 ||
      hdiutil detach -force "$MOUNT_DIR" >/dev/null 2>&1 || true
    MOUNTED=0
  fi
  if [ -n "${WORKDIR:-}" ] && [ -d "$WORKDIR" ]; then
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

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    openssl dgst -sha256 "$1" | awk '{print $NF}'
  fi
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

  printf '%s\n' "$PUBKEY_PEM" > "$dir/spotifast-release-key.pem"
  openssl pkeyutl -verify -pubin -inkey "$dir/spotifast-release-key.pem" \
    -rawin -in "$dir/checksums.txt" -sigfile "$dir/checksums.txt.sig" \
    >/dev/null 2>&1
}

version_ge() {
  # Return success when $1 is greater than or equal to $2.
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n 1)" = "$2" ]
}

desktop_quote() {
  # Escape the characters the Desktop Entry spec reserves inside quoted Exec
  # arguments. The sed expressions contain literal $ and ` characters.
  # shellcheck disable=SC2016
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/`/\\`/g' -e 's/\$/\\$/g' -e 's/%/%%/g'
}

write_fallback_icon() {
  cat <<'SPOTIFAST_ICON'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 128 128" width="128" height="128">
  <defs>
    <linearGradient id="rim" x1="0" y1="2" x2="0" y2="126" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#18c055"/><stop offset="1" stop-color="#0c8a3a"/></linearGradient>
    <linearGradient id="face" x1="0" y1="8" x2="0" y2="120" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#5cf095"/><stop offset="0.55" stop-color="#1ed760"/><stop offset="1" stop-color="#15b650"/></linearGradient>
    <linearGradient id="edge" x1="0" y1="8" x2="0" y2="120" gradientUnits="userSpaceOnUse"><stop offset="0" stop-color="#d9ffe8"/><stop offset="0.5" stop-color="#7bf0aa" stop-opacity="0.35"/><stop offset="1" stop-color="#0a6e2e" stop-opacity="0.9"/></linearGradient>

  </defs>
  <circle cx="64" cy="64" r="62" fill="url(#rim)"/>
  <circle cx="64" cy="64" r="54.4" fill="url(#face)"/>
  <circle cx="64" cy="64" r="55" fill="none" stroke="url(#edge)" stroke-width="1.2"/>
  <g transform="translate(0 1.6)">
  <path d="M44.2 43.5 A5 5 0 0 1 51.63 39.13 L88.53 59.63 A5 5 0 0 1 88.53 68.37 L51.63 88.87 A5 5 0 0 1 44.2 84.5 Z" fill="#000" fill-opacity="0.155"/>
  <path d="M44.2 43.5 A5 5 0 0 1 51.63 39.13 L88.53 59.63 A5 5 0 0 1 88.53 68.37 L51.63 88.87 A5 5 0 0 1 44.2 84.5 Z" fill="none" stroke="#000" stroke-opacity="0.006" stroke-width="1.2" stroke-linejoin="round"/>
  <path d="M44.2 43.5 A5 5 0 0 1 51.63 39.13 L88.53 59.63 A5 5 0 0 1 88.53 68.37 L51.63 88.87 A5 5 0 0 1 44.2 84.5 Z" fill="none" stroke="#000" stroke-opacity="0.034" stroke-width="2.6" stroke-linejoin="round"/>
  <path d="M44.2 43.5 A5 5 0 0 1 51.63 39.13 L88.53 59.63 A5 5 0 0 1 88.53 68.37 L51.63 88.87 A5 5 0 0 1 44.2 84.5 Z" fill="none" stroke="#000" stroke-opacity="0.054" stroke-width="4.2" stroke-linejoin="round"/>
  <path d="M44.2 43.5 A5 5 0 0 1 51.63 39.13 L88.53 59.63 A5 5 0 0 1 88.53 68.37 L51.63 88.87 A5 5 0 0 1 44.2 84.5 Z" fill="none" stroke="#000" stroke-opacity="0.015" stroke-width="6.0" stroke-linejoin="round"/>
</g>
<path d="M44.2 43.5 A5 5 0 0 1 51.63 39.13 L88.53 59.63 A5 5 0 0 1 88.53 68.37 L51.63 88.87 A5 5 0 0 1 44.2 84.5 Z" fill="#0b0e0c"/>
</svg>
SPOTIFAST_ICON
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

### Linux

check_linux_platform() {
  [ -n "${HOME:-}" ] || die "HOME is not set"

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
  command -v awk >/dev/null 2>&1 || die "awk is required."
  command -v sort >/dev/null 2>&1 || die "sort is required (package coreutils)."
  command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required (package coreutils)."
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

install_linux_appimage() {
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
  actual="$(sha256_file "$WORKDIR/$asset")"
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
  rm -f "$INSTALL_DIR/VERSION" "$INSTALL_DIR/spotifast-update"

  APPIMAGE="$INSTALL_DIR/Spotifast.AppImage"
}

install_linux_launcher() {
  local launcher="$INSTALL_DIR/spotifast-launcher"

  mkdir -p "$INSTALL_DIR" "$BIN_DIR" || die "Could not create installation directories."

  cat > "$launcher" <<'SPOTIFAST_LAUNCHER'
#!/usr/bin/env bash
# Internal Spotifast launcher. It only chooses the AppImage runtime mode.
set -u

SOURCE="${BASH_SOURCE[0]:-$0}"
if command -v readlink >/dev/null 2>&1; then
  SELF="$(readlink -f -- "$SOURCE" 2>/dev/null || printf '%s' "$SOURCE")"
else
  SELF="$SOURCE"
fi
INSTALL_DIR="$(cd -- "$(dirname -- "$SELF")" && pwd -P)"
APPIMAGE="$INSTALL_DIR/Spotifast.AppImage"
RUN_MODE="$(cat "$INSTALL_DIR/run-mode" 2>/dev/null || printf 'direct')"

if [ ! -x "$APPIMAGE" ]; then
  printf 'Spotifast is not installed correctly: %s is missing or not executable.\n' "$APPIMAGE" >&2
  printf 'Reinstall it with the Spotifast install script.\n' >&2
  exit 1
fi

if [ "$RUN_MODE" = "extract" ]; then
  exec "$APPIMAGE" --appimage-extract-and-run "$@"
fi
exec "$APPIMAGE" "$@"
SPOTIFAST_LAUNCHER
  chmod 755 "$launcher" || die "Could not make the launcher executable."

  if [ -e "$BIN_DIR/spotifast" ] && [ ! -L "$BIN_DIR/spotifast" ]; then
    warn "$BIN_DIR/spotifast already exists and is not a symlink; leaving it alone."
    warn "Use $launcher instead."
  else
    ln -sfn "$launcher" "$BIN_DIR/spotifast" ||
      die "Could not create $BIN_DIR/spotifast"
  fi

  # Remove the helper from older versions of this installer.
  remove_symlink "$BIN_DIR/spotifast-update" "$INSTALL_DIR/spotifast-update" || true
  rm -f "$INSTALL_DIR/spotifast-update"
  rm -rf "$INSTALLER_STATE_DIR" 2>/dev/null || true
}

install_linux_desktop() {
  local icon_source="" launcher

  mkdir -p "$APPS_DIR" "$ICON_DIR" || die "Could not create desktop integration directories."

  if [ -x "$APPIMAGE" ] && [ -n "$WORKDIR" ]; then
    mkdir -p "$WORKDIR/icon" 2>/dev/null || true
    if ( cd "$WORKDIR/icon" && "$APPIMAGE" --appimage-extract spotifast.svg >/dev/null 2>&1 ); then
      icon_source="$WORKDIR/icon/squashfs-root/spotifast.svg"
    fi
  fi

  if [ -z "$icon_source" ]; then
    warn "Could not read the icon from the AppImage; using the bundled icon."
    write_fallback_icon > "$ICON_DIR/spotifast.svg" || die "Could not install the icon."
  else
    cp "$icon_source" "$ICON_DIR/spotifast.svg" || die "Could not install the icon."
  fi
  chmod 644 "$ICON_DIR/spotifast.svg"

  launcher="$(desktop_quote "$INSTALL_DIR/spotifast-launcher")"

  {
    printf '%s\n' \
      '[Desktop Entry]' \
      'Type=Application' \
      'Version=1.0' \
      'Name=Spotifast' \
      'GenericName=Music Player' \
      'Comment=A native Spotify client' \
      "Exec=\"$launcher\" %u"
    printf '%s\n' \
      'Terminal=false' \
      'Categories=AudioVideo;Audio;Player;Music;' \
      'Keywords=spotify;music;player;streaming;spotifast;' \
      'Icon=spotifast' \
      'StartupNotify=true' \
      'StartupWMClass=spotifast' \
      'MimeType=x-scheme-handler/spotify;'
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

print_linux_summary() {
  local installed
  installed="$("$APPIMAGE" --version 2>/dev/null | awk 'NR == 1 { print $NF }')"
  [ -n "$installed" ] || installed="${VERSION:-unknown}"

  printf '\n'
  info "Spotifast $installed is installed."
  printf '\n'
  printf '  Application   %s\n' "$APPIMAGE"
  printf '  Command       %s\n' "$BIN_DIR/spotifast"
  printf '  Updates       built into Spotifast (green update button or Settings)\n'
  printf '\n'
  printf 'Open %sSpotifast%s from your application menu. If it is not there yet,\n' "$C_BOLD" "$C_RESET"
  printf 'log out and back in, or run: update-desktop-database %s\n' "$APPS_DIR"

  case ":$PATH:" in
    *":$BIN_DIR:"*)
      ;;
    *)
      printf '\n'
      warn "$BIN_DIR is not on your PATH. The app menu still works."
      warn "To use the 'spotifast' command, add this to your shell profile:"
      # shellcheck disable=SC2016
      printf '  export PATH="%s:$PATH"\n' "$BIN_DIR"
      ;;
  esac

  printf '\n'
  printf '%sSpotify playback requires Spotify Premium.%s\n' "$C_DIM" "$C_RESET"
}

do_linux_uninstall() {
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

### macOS

check_macos_platform() {
  [ "$(uname -s)" = "Darwin" ] || die "This script is for macOS only."
  [ -n "${HOME:-}" ] || die "HOME is not set"

  local cmd
  for cmd in curl hdiutil ditto codesign spctl shasum xattr mktemp awk sed; do
    command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required."
  done
  [ -x "$PLIST_BUDDY" ] || die "$PLIST_BUDDY is required."
}

macos_current_version() {
  [ -d "$MAC_APP_BUNDLE" ] || return 1
  local value
  value="$("$PLIST_BUDDY" -c 'Print :CFBundleShortVersionString' \
    "$MAC_APP_BUNDLE/Contents/Info.plist" 2>/dev/null | tr -d '\r' | head -n 1)"
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

download_macos_release() {
  local version="$1"
  local asset="spotifast-v${version}-macos-universal.dmg"
  local base="https://github.com/$UPSTREAM_REPO/releases/download/v${version}"
  local expected actual

  if [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ]; then
    rm -rf "$WORKDIR"
  fi
  WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/spotifast-install.XXXXXXXX")" ||
    die "Could not create a temporary directory."
  DMG_PATH="$WORKDIR/$asset"

  info "Downloading Spotifast ${C_BOLD}$version${C_RESET} for macOS..."
  download "$base/$asset" "$DMG_PATH" ||
    die "Download failed. Check your connection and try again."
  download_quiet "$base/checksums.txt" "$WORKDIR/checksums.txt" ||
    die "Could not download checksums.txt."
  download_quiet "$base/checksums.txt.sig" "$WORKDIR/checksums.txt.sig" ||
    die "Could not download checksums.txt.sig."

  verify_signature "$WORKDIR" || die "The release signature is not valid. Aborting."

  expected="$(awk -v file="$asset" '{ name = $2; sub(/^\*/, "", name); if (name == file) { print $1; exit } }' "$WORKDIR/checksums.txt")"
  [ -n "$expected" ] || die "The release does not publish a checksum for $asset."
  actual="$(sha256_file "$DMG_PATH")"
  [ "$expected" = "$actual" ] ||
    die "The downloaded DMG does not match its published checksum. Aborting."
}

detach_dmg() {
  if [ "$MOUNTED" -eq 1 ] && [ -n "$MOUNT_DIR" ]; then
    hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 ||
      hdiutil detach -force "$MOUNT_DIR" >/dev/null 2>&1 || true
    MOUNTED=0
  fi
}

install_macos_app_bundle() {
  local src="$1"
  local new_app="$MAC_APP_DIR/.Spotifast.app.new.$$"
  local old_app="$MAC_APP_DIR/.Spotifast.app.old.$$"

  mkdir -p "$MAC_APP_DIR" || die "Could not create $MAC_APP_DIR."
  rm -rf "$new_app" "$old_app"

  ditto "$src" "$new_app" || die "Could not copy Spotifast.app."
  codesign --verify --deep --strict "$new_app" >/dev/null 2>&1 || {
    rm -rf "$new_app"
    die "The copied app failed its code-signature check."
  }
  xattr -dr com.apple.quarantine "$new_app" >/dev/null 2>&1 || true

  if [ -e "$MAC_APP_BUNDLE" ]; then
    mv "$MAC_APP_BUNDLE" "$old_app" || die "Could not move the existing Spotifast.app aside."
  fi
  if ! mv "$new_app" "$MAC_APP_BUNDLE"; then
    if [ -e "$old_app" ]; then
      mv "$old_app" "$MAC_APP_BUNDLE" >/dev/null 2>&1 || true
    fi
    die "Could not replace $MAC_APP_BUNDLE."
  fi
  rm -rf "$old_app"

  if [ -x "$LSREGISTER" ]; then
    "$LSREGISTER" -f "$MAC_APP_BUNDLE" >/dev/null 2>&1 || true
  fi
}

install_macos_dmg() {
  local dmg="$1"
  local version="$2"
  local app_src bundle_version

  MOUNT_DIR="$WORKDIR/mnt"
  mkdir -p "$MOUNT_DIR" || die "Could not create a mount point."
  info "Mounting the release image..."
  hdiutil attach -nobrowse -readonly -mountpoint "$MOUNT_DIR" "$dmg" >/dev/null ||
    die "Could not mount the Spotifast DMG."
  MOUNTED=1

  app_src="$MOUNT_DIR/Spotifast.app"
  if [ ! -d "$app_src" ]; then
    app_src="$(find "$MOUNT_DIR" -type d -name 'Spotifast.app' -print | head -n 1)"
  fi
  [ -n "$app_src" ] || die "Could not find Spotifast.app in the DMG."

  info "Checking the app signature..."
  codesign --verify --deep --strict "$app_src" >/dev/null 2>&1 ||
    die "The app's code signature is not valid. Aborting."
  if ! spctl --assess --type execute "$app_src" >/dev/null 2>&1; then
    if [ "$FORCE" -eq 1 ]; then
      warn "Gatekeeper could not assess the app; continuing because --force was given."
    else
      die "Gatekeeper could not assess the app. Rerun with --force only if you trust this release."
    fi
  fi

  bundle_version="$("$PLIST_BUDDY" -c 'Print :CFBundleShortVersionString' \
    "$app_src/Contents/Info.plist" 2>/dev/null | tr -d '\r' | head -n 1)"
  [ "$bundle_version" = "$version" ] ||
    die "The app reports version '$bundle_version', expected '$version'."

  install_macos_app_bundle "$app_src"
  detach_dmg

  mkdir -p "$MAC_STATE_DIR" 2>/dev/null || true
  printf '%s\n' "$MAC_APP_DIR" > "$MAC_STATE_DIR/app-dir" 2>/dev/null || true
  rm -f "$MAC_STATE_DIR/installed-version" 2>/dev/null || true
}

install_macos_commands() {
  local tmp_cli="$BIN_DIR/.spotifast.new.$$"

  mkdir -p "$BIN_DIR" || die "Could not create $BIN_DIR."

  {
    printf '#!/bin/sh\n'
    printf '# Spotifast CLI wrapper.\n'
    printf 'exec "%s" %s\n' "$MAC_APP_BUNDLE/Contents/MacOS/Spotifast" '"$@"'
  } > "$tmp_cli" || {
    rm -f "$tmp_cli"
    die "Could not create the Spotifast CLI wrapper."
  }
  chmod 755 "$tmp_cli"
  mv -f "$tmp_cli" "$BIN_DIR/spotifast" || die "Could not install the Spotifast CLI wrapper."

  # Remove the updater installed by older versions of this installer.
  if [ -f "$BIN_DIR/spotifast-update" ] &&
     grep -q 'Spotifast installer/updater for macOS' "$BIN_DIR/spotifast-update" 2>/dev/null; then
    rm -f "$BIN_DIR/spotifast-update"
  fi
  rm -rf "$MAC_LEGACY_LOG_DIR" 2>/dev/null || true
}

print_macos_summary() {
  local installed
  installed="$(macos_current_version 2>/dev/null || printf '%s' "$VERSION")"

  printf '\n'
  info "Spotifast $installed is installed."
  printf '\n'
  printf '  Application   %s\n' "$MAC_APP_BUNDLE"
  printf '  CLI           %s\n' "$BIN_DIR/spotifast"
  printf '  Updates       built into Spotifast (green update button or Spotifast menu)\n'
  printf '\n'
  printf 'Open Spotifast from Launchpad or the Applications folder.\n'

  case ":$PATH:" in
    *":$BIN_DIR:"*)
      ;;
    *)
      printf '\n'
      warn "$BIN_DIR is not on your PATH."
      warn "Run the command with its full path, or add this to your shell profile:"
      # shellcheck disable=SC2016
      printf '  export PATH="%s:$PATH"\n' "$BIN_DIR"
      ;;
  esac

  printf '\n'
  printf '%sSpotify playback requires Spotify Premium.%s\n' "$C_DIM" "$C_RESET"
}

remove_macos_app_bundle() {
  local path="$1"

  [ -e "$path" ] || return 0
  if [ -w "$(dirname "$path")" ]; then
    if rm -rf "$path"; then
      info "Removed $path"
    else
      warn "Could not remove $path."
    fi
  else
    warn "Could not remove $path (permission denied)."
    warn "Remove it manually with: sudo rm -rf \"$path\""
  fi
}

do_macos_uninstall() {
  local other_app="/Applications/Spotifast.app"

  check_macos_platform
  info "Removing Spotifast..."

  if [ -x "$LSREGISTER" ]; then
    if [ -e "$MAC_APP_BUNDLE" ]; then
      "$LSREGISTER" -u "$MAC_APP_BUNDLE" >/dev/null 2>&1 || true
    fi
    if [ -e "$other_app" ]; then
      "$LSREGISTER" -u "$other_app" >/dev/null 2>&1 || true
    fi
  fi

  remove_macos_app_bundle "$MAC_APP_BUNDLE"
  [ "$other_app" != "$MAC_APP_BUNDLE" ] && remove_macos_app_bundle "$other_app"

  if [ -f "$BIN_DIR/spotifast-update" ] &&
     grep -q 'Spotifast installer/updater for macOS' "$BIN_DIR/spotifast-update" 2>/dev/null; then
    rm -f "$BIN_DIR/spotifast-update"
  fi
  if [ -f "$BIN_DIR/spotifast" ] &&
     grep -q 'Spotifast CLI wrapper' "$BIN_DIR/spotifast" 2>/dev/null; then
    rm -f "$BIN_DIR/spotifast"
  fi

  rm -rf "$MAC_STATE_DIR" "$MAC_LEGACY_LOG_DIR"

  if [ "$PURGE" -eq 1 ]; then
    rm -rf "$HOME/Library/Application Support/me.paolino.spotifast"
    rm -rf "$HOME/Library/Caches/me.paolino.spotifast"
    info "Removed Spotifast settings, caches, and local state."
    printf 'Spotify grants in the macOS Keychain were not touched. To revoke them,\n'
    printf 'reinstall Spotifast, open Settings, and use Sign out before uninstalling.\n'
  else
    printf '\n'
    printf 'Settings and local state were kept in:\n'
    printf '  %s\n' "$HOME/Library/Application Support/me.paolino.spotifast"
    printf '  %s\n' "$HOME/Library/Caches/me.paolino.spotifast"
    printf 'Run with --uninstall --purge to remove those too.\n'
  fi

  info "Spotifast was uninstalled."
}

macos_install() {
  local target="$VERSION"

  check_macos_platform
  if [ -z "$target" ]; then
    info "Finding the latest Spotifast release..."
    target="$(latest_version)" ||
      die "Could not determine the latest release. Check your connection or pass --version X.Y.Z."
  fi

  download_macos_release "$target"
  install_macos_dmg "$DMG_PATH" "$target"
  install_macos_commands
  VERSION="$target"
  print_macos_summary
}

### Main

main() {
  parse_args "$@"

  case "$OS" in
    Linux)
      if [ "$UNINSTALL" -eq 1 ]; then
        do_linux_uninstall
        return 0
      fi

      check_linux_platform
      check_glibc

      info "Installing Spotifast for the current user..."
      install_linux_appimage
      install_linux_launcher
      install_linux_desktop
      print_linux_summary
      ;;
    Darwin)
      if [ "$UNINSTALL" -eq 1 ]; then
        do_macos_uninstall
        return 0
      fi

      macos_install
      ;;
    *)
      die "Unsupported operating system: $OS. This installer supports Linux and macOS."
      ;;
  esac
}

main "$@"
