#!/usr/bin/env bash
# Spotifast installer/updater for macOS.
#
# Installs the official universal Spotifast.app from the signed GitHub release
# DMG into ~/Applications, registers it with LaunchServices, and installs a
# manual updater and CLI wrapper in ~/.local/bin.
#
# The same file is installed as ~/.local/bin/spotifast-update. When its name is
# spotifast-update it defaults to update mode.
#
set -u -o pipefail
: "${HOME:?HOME is not set}"

UPSTREAM_REPO="crmne/spotifast"
STATE_DIR="$HOME/Library/Application Support/spotifast-install"
APP_DIR="${SPOTIFAST_APP_DIR:-}"
if [ -z "$APP_DIR" ] && [ -f "$STATE_DIR/app-dir" ]; then
  APP_DIR="$(cat "$STATE_DIR/app-dir" 2>/dev/null || true)"
fi
[ -n "$APP_DIR" ] || APP_DIR="$HOME/Applications"
APP_BUNDLE="$APP_DIR/Spotifast.app"
if [ -n "${SPOTIFAST_BIN_DIR:-}" ]; then
  BIN_DIR="$SPOTIFAST_BIN_DIR"
elif [ "$(basename "$0")" = "spotifast-update" ]; then
  BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
else
  BIN_DIR="$HOME/.local/bin"
fi
LOG_DIR="$HOME/Library/Logs/spotifast-install"
LOG="$LOG_DIR/update.log"
RAW_BASE="${SPOTIFAST_REPO_RAW:-https://raw.githubusercontent.com/imdonix/spotifast-install/main}"
PLIST_BUDDY="${SPOTIFAST_PLIST_BUDDY:-/usr/libexec/PlistBuddy}"
LSREGISTER="${SPOTIFAST_LSREGISTER:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"

# Pinned Spotifast release signing key. Keep this in sync with install.sh.
PUBKEY_PEM='-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEA5EyHsVUEhMaHlHvZJ64zP/QxzHrcbMM1M8Yo+CAWtVQ=
-----END PUBLIC KEY-----'

MODE="install"
VERSION=""
FORCE=0
UNINSTALL=0
PURGE=0
CHECK_ONLY=0
WORKDIR=""
MOUNT_DIR=""
MOUNTED=0
DMG_PATH=""

case "$(basename "$0")" in
  spotifast-update|spotifast-update.sh)
    MODE="update"
    ;;
esac

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
${C_BOLD}Spotifast installer/updater for macOS${C_RESET}

Usage:
  install.sh                       install the latest release (via the Unix installer)
  spotifast-update                 check and install updates
  spotifast-update --check         only report whether an update is available
  spotifast-update --version X.Y.Z install a specific release
  spotifast-update --uninstall     remove the app, keep settings
  spotifast-update --uninstall --purge
                                   remove the app and local app data

Environment:
  SPOTIFAST_APP_DIR                applications directory (default: ~/Applications)
  SPOTIFAST_BIN_DIR                command directory (default: ~/.local/bin)
  SPOTIFAST_REPO_RAW               raw base for installer files (forks/testing)
EOF
}

log() {
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$LOG" 2>/dev/null || true
}

cleanup() {
  if [ "$MOUNTED" -eq 1 ] && [ -n "$MOUNT_DIR" ]; then
    hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 ||
      hdiutil detach -force "$MOUNT_DIR" >/dev/null 2>&1 || true
    MOUNTED=0
  fi
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
      --check)
        CHECK_ONLY=1
        MODE="update"
        ;;
      --update|--foreground|--now)
        MODE="update"
        ;;
      --uninstall)
        UNINSTALL=1
        ;;
      --purge)
        PURGE=1
        ;;
      --force)
        FORCE=1
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

check_platform() {
  [ "$(uname -s)" = "Darwin" ] || die "This script is for macOS only."
  [ -n "${HOME:-}" ] || die "HOME is not set"

  local cmd
  for cmd in curl hdiutil ditto codesign spctl shasum xattr mktemp awk sed; do
    command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required."
  done
  [ -x "$PLIST_BUDDY" ] || die "$PLIST_BUDDY is required."
}

version_gt() {
  # Return success when version $1 is newer than $2. Works with bash 3.2.
  local a="$1"
  local b="$2"
  local i x y
  local IFS=.
  local -a av bv
  read -r -a av <<< "$a"
  read -r -a bv <<< "$b"

  for ((i = 0; i < ${#av[@]} || i < ${#bv[@]}; i++)); do
    x="${av[i]:-0}"
    y="${bv[i]:-0}"
    x="${x//[!0-9]/}"
    y="${y//[!0-9]/}"
    [ -n "$x" ] || x=0
    [ -n "$y" ] || y=0
    if ((10#$x > 10#$y)); then
      return 0
    fi
    if ((10#$x < 10#$y)); then
      return 1
    fi
  done
  return 1
}

is_newer() {
  # Return success when $2 is newer than $1.
  [ -n "$2" ] || return 1
  [ -z "$1" ] && return 0
  [ "$1" = "$2" ] && return 1
  version_gt "$2" "$1"
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

current_version() {
  [ -d "$APP_BUNDLE" ] || return 1
  local value
  value="$("$PLIST_BUDDY" -c 'Print :CFBundleShortVersionString' \
    "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null | tr -d '\r' | head -n 1)"
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

download_file() {
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
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    openssl dgst -sha256 "$1" | awk '{print $NF}'
  fi
}

verify_signature() {
  local dir="$1"

  if ! command -v openssl >/dev/null 2>&1; then
    warn "openssl not found; skipping the Ed25519 checksum signature (SHA-256 and Apple code signing are still verified)."
    return 0
  fi

  case "$(openssl version 2>/dev/null)" in
    "OpenSSL 3."*|"OpenSSL 4."*|"OpenSSL 5."*)
      ;;
    *)
      warn "macOS OpenSSL/LibreSSL cannot verify the Ed25519 checksum signature; relying on SHA-256 and Apple code signing."
      return 0
      ;;
  esac

  printf '%s\n' "$PUBKEY_PEM" > "$dir/spotifast-update-key.pem"
  openssl pkeyutl -verify -pubin -inkey "$dir/spotifast-update-key.pem" \
    -rawin -in "$dir/checksums.txt" -sigfile "$dir/checksums.txt.sig" \
    >/dev/null 2>&1
}

detach_dmg() {
  if [ "$MOUNTED" -eq 1 ] && [ -n "$MOUNT_DIR" ]; then
    hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 ||
      hdiutil detach -force "$MOUNT_DIR" >/dev/null 2>&1 || true
    MOUNTED=0
  fi
}

download_release() {
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
  download_file "$base/$asset" "$DMG_PATH" ||
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

install_app_bundle() {
  local src="$1"
  local new_app="$APP_DIR/.Spotifast.app.new.$$"
  local old_app="$APP_DIR/.Spotifast.app.old.$$"

  mkdir -p "$APP_DIR" || die "Could not create $APP_DIR."
  rm -rf "$new_app" "$old_app"

  ditto "$src" "$new_app" || die "Could not copy Spotifast.app."
  codesign --verify --deep --strict "$new_app" >/dev/null 2>&1 || {
    rm -rf "$new_app"
    die "The copied app failed its code-signature check."
  }
  xattr -dr com.apple.quarantine "$new_app" >/dev/null 2>&1 || true

  if [ -e "$APP_BUNDLE" ]; then
    mv "$APP_BUNDLE" "$old_app" || die "Could not move the existing Spotifast.app aside."
  fi
  if ! mv "$new_app" "$APP_BUNDLE"; then
    if [ -e "$old_app" ]; then
      mv "$old_app" "$APP_BUNDLE" >/dev/null 2>&1 || true
    fi
    die "Could not replace $APP_BUNDLE."
  fi
  rm -rf "$old_app"

  if [ -x "$LSREGISTER" ]; then
    "$LSREGISTER" -f "$APP_BUNDLE" >/dev/null 2>&1 || true
  fi
}

install_dmg() {
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

  install_app_bundle "$app_src"
  detach_dmg

  mkdir -p "$STATE_DIR" 2>/dev/null || true
  printf '%s\n' "$version" > "$STATE_DIR/installed-version" 2>/dev/null || true
  printf '%s\n' "$APP_DIR" > "$STATE_DIR/app-dir" 2>/dev/null || true
  log "installed $version to $APP_BUNDLE"
}

install_commands() {
  local source="${BASH_SOURCE[0]:-$0}"
  local tmp_update="$BIN_DIR/.spotifast-update.new.$$"
  local tmp_cli="$BIN_DIR/.spotifast.new.$$"

  mkdir -p "$BIN_DIR" || die "Could not create $BIN_DIR."

  if [ -f "$source" ]; then
    cp "$source" "$tmp_update" || {
      rm -f "$tmp_update"
      die "Could not install the updater."
    }
  else
    download_quiet "$RAW_BASE/lib/install-macos.sh" "$tmp_update" || {
      rm -f "$tmp_update"
      die "Could not download the updater."
    }
  fi
  chmod 755 "$tmp_update"
  mv -f "$tmp_update" "$BIN_DIR/spotifast-update" || die "Could not install the updater."

  {
    printf '#!/bin/sh\n'
    printf '# Spotifast CLI wrapper.\n'
    printf 'exec "%s" %s\n' "$APP_BUNDLE/Contents/MacOS/Spotifast" '"$@"'
  } > "$tmp_cli" || {
    rm -f "$tmp_cli"
    die "Could not create the Spotifast CLI wrapper."
  }
  chmod 755 "$tmp_cli"
  mv -f "$tmp_cli" "$BIN_DIR/spotifast" || die "Could not install the Spotifast CLI wrapper."
}

print_summary() {
  local installed
  installed="$(current_version 2>/dev/null || printf '%s' "$VERSION")"

  printf '\n'
  info "Spotifast $installed is installed."
  printf '\n'
  printf '  Application   %s\n' "$APP_BUNDLE"
  printf '  CLI           %s\n' "$BIN_DIR/spotifast"
  printf '  Updater       %s\n' "$BIN_DIR/spotifast-update"
  printf '  Update log    %s\n' "$LOG"
  printf '\n'
  printf 'Open Spotifast from Launchpad or the Applications folder.\n'
  printf 'Spotifast also updates itself from its own interface; the updater above\n'
  printf 'is available for a manual check or a forced install.\n'

  case ":$PATH:" in
    *":$BIN_DIR:"*)
      ;;
    *)
      printf '\n'
      warn "$BIN_DIR is not on your PATH."
      warn "Run the commands with their full paths, or add this to your shell profile:"
      # shellcheck disable=SC2016
      printf '  export PATH="%s:$PATH"\n' "$BIN_DIR"
      ;;
  esac

  printf '\n'
  printf '%sSpotify playback requires Spotify Premium.%s\n' "$C_DIM" "$C_RESET"
}

remove_app_bundle() {
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

do_uninstall() {
  local other_app="/Applications/Spotifast.app"

  check_platform
  info "Removing Spotifast..."

  if [ -x "$LSREGISTER" ]; then
    if [ -e "$APP_BUNDLE" ]; then
      "$LSREGISTER" -u "$APP_BUNDLE" >/dev/null 2>&1 || true
    fi
    if [ -e "$other_app" ]; then
      "$LSREGISTER" -u "$other_app" >/dev/null 2>&1 || true
    fi
  fi

  remove_app_bundle "$APP_BUNDLE"
  [ "$other_app" != "$APP_BUNDLE" ] && remove_app_bundle "$other_app"

  if [ -f "$BIN_DIR/spotifast-update" ] &&
     grep -q 'Spotifast installer/updater for macOS' "$BIN_DIR/spotifast-update" 2>/dev/null; then
    rm -f "$BIN_DIR/spotifast-update"
  fi
  if [ -f "$BIN_DIR/spotifast" ] &&
     grep -q 'Spotifast CLI wrapper' "$BIN_DIR/spotifast" 2>/dev/null; then
    rm -f "$BIN_DIR/spotifast"
  fi

  rm -rf "$STATE_DIR" "$LOG_DIR"

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

do_check() {
  local current latest

  current="$(current_version)" ||
    die "Spotifast is not installed in $APP_BUNDLE. Run the installer first."
  latest="${VERSION:-$(latest_version)}" ||
    die "Could not determine the latest release."

  if is_newer "$current" "$latest"; then
    printf 'Spotifast %s is available (installed: %s).\n' "$latest" "$current"
  else
    printf 'Spotifast %s is up to date.\n' "$current"
  fi
}

do_install() {
  local target="$VERSION"

  check_platform
  if [ -z "$target" ]; then
    info "Finding the latest Spotifast release..."
    target="$(latest_version)" ||
      die "Could not determine the latest release. Check your connection or pass --version X.Y.Z."
  fi

  if [ "$CHECK_ONLY" -eq 1 ]; then
    VERSION="$target"
    do_check
    return
  fi

  download_release "$target"
  install_dmg "$DMG_PATH" "$target"
  install_commands
  VERSION="$target"
  print_summary
}

do_update() {
  local current latest

  check_platform
  current="$(current_version)" ||
    die "Spotifast is not installed in $APP_BUNDLE. Run the installer first."
  latest="${VERSION:-$(latest_version)}" ||
    die "Could not determine the latest release."

  if ! is_newer "$current" "$latest"; then
    info "Spotifast $current is up to date."
    install_commands
    return
  fi

  if [ "$CHECK_ONLY" -eq 1 ]; then
    printf 'Spotifast %s is available (installed: %s).\n' "$latest" "$current"
    return
  fi

  info "Updating Spotifast $current -> $latest..."
  download_release "$latest"
  install_dmg "$DMG_PATH" "$latest"
  install_commands
  VERSION="$latest"
  info "Updated to Spotifast $latest."
  printf 'Restart Spotifast to use the new version.\n'
}

main() {
  parse_args "$@"

  if [ "$UNINSTALL" -eq 1 ]; then
    do_uninstall
    return 0
  fi

  case "$MODE" in
    update)
      if [ "$CHECK_ONLY" -eq 1 ]; then
        do_check
      else
        do_update
      fi
      ;;
    *)
      do_install
      ;;
  esac
}

main "$@"
