# Spotifast Linux Installer — Technical Notes

This is the detailed companion to the short [README](README.md). It covers what the installer changes, how updates work, requirements, paths, troubleshooting, and security.

## Why this installer?

Spotifast already offers official [downloads](https://spotifast.rocks/download/): AppImage, DEB, RPM, Flatpak, AUR, and Nix. This project covers the gap for Ubuntu-based desktops that want:

- a **per-user install** without `sudo` or adding a repository;
- a proper **application-menu entry, icon, and `spotify:` link handler**;
- **automatic background updates** from the official GitHub releases;
- a clean **uninstall** that leaves settings and local state intact.

It downloads the official AppImage, verifies it, and places it under your home directory. The only files it touches outside that directory are normal XDG launcher, desktop, icon, and updater-state files under your home.

## What the installer does

1. Detects your CPU architecture (`x86_64` or `aarch64`) and checks the glibc version.
2. Finds the latest [official Spotifast release](https://github.com/crmne/spotifast/releases).
3. Downloads the release AppImage plus `checksums.txt` and `checksums.txt.sig`.
4. Verifies the **Ed25519 signature** of the checksums with Spotifast's pinned public key, then verifies the **SHA-256 checksum** of the AppImage.
5. Tests that the AppImage can actually run before replacing an existing installation.
6. Installs the app, launcher, updater, desktop entry, and icon.
7. Registers `spotifast.desktop` for `spotify:` links if no handler is set yet.

If FUSE is unavailable (common on newer Ubuntu releases), the launcher automatically uses the AppImage's `--appimage-extract-and-run` fallback. Nothing extra needs to be installed.

## Where things go

| What | Path |
| --- | --- |
| AppImage | `~/.local/opt/spotifast/Spotifast.AppImage` |
| Launcher | `~/.local/bin/spotifast` |
| Updater | `~/.local/bin/spotifast-update` |
| Desktop entry | `~/.local/share/applications/spotifast.desktop` |
| Icon | `~/.local/share/icons/hicolor/scalable/apps/spotifast.svg` |
| Update log | `~/.local/state/spotifast-install/update.log` |
| Settings and sign-ins | `~/.config/spotifast` and the system keyring (managed by Spotifast) |

`XDG_BIN_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME`, and `SPOTIFAST_INSTALL_DIR` are respected.

## Updates

**Recommended: background updates.** Spotifast does not expose an external-updater hook, so this is wired into the launcher that the application menu calls. The launcher starts `spotifast-update --auto` as a detached background process, then opens Spotifast immediately. It checks at most once every 24 hours. If a newer release exists, it downloads and verifies it, replaces the AppImage in place, and sends a desktop notification. The new version is used the next time Spotifast starts. Nothing blocks or delays the launch, and there is no extra window.

You can also update on demand:

```bash
spotifast-update            # small GUI if zenity is available, terminal otherwise
spotifast-update --gui      # force the zenity dialogs
spotifast-update --check    # only report whether an update is available
spotifast-update --foreground
                            # check and update in the terminal
```

Or right-click the Spotifast icon in your application menu and choose **Check for Updates**.

The updater:

- only downloads from `github.com/crmne/spotifast/releases`;
- verifies the release's Ed25519 signature and SHA-256 checksum;
- runs the new AppImage's `--version` before replacing the working copy;
- keeps the old AppImage usable if verification or the smoke test fails;
- writes details to `~/.local/state/spotifast-install/update.log`.

Spotifast also has its own built-in AppImage updater. Both updaters use the same signed releases and replace the same file, so leaving the built-in one enabled is safe.

The updater replaces only the AppImage. If this repository later changes the launcher or desktop integration, re-run the install command to refresh those files.

### Foreground GUI

If you prefer to wait for an update, `spotifast-update` opens a small **zenity** window that explains what it is doing while it checks and downloads, then tells you when it is done. This is the "trivial GUI" path: it explains the wait without adding another dependency to the app. Install `zenity` if your desktop does not include it:

```bash
sudo apt install zenity libnotify-bin
```

Without `zenity`, the updater falls back to terminal output. Without `notify-send`, background updates still work silently and are recorded in the log.

## Requirements

- **Linux** on `x86_64` or `aarch64`.
- **glibc 2.39 or newer**: Ubuntu 24.04+, Linux Mint 22+, Debian 13+, Fedora 41+, or a newer distribution. Spotifast's current Linux builds will not start on Ubuntu 22.04.
- `curl`, `sha256sum`, `awk`, and `sort` (all standard on Ubuntu).
- `openssl` 3+ for the release signature check. Without it, the installer still verifies the SHA-256 checksum but prints a warning.
- Optional: `zenity` for the update GUI, `notify-send` for update notifications, FUSE for the fastest AppImage startup.
- A desktop environment that follows the XDG desktop-entry and icon specifications (GNOME, KDE Plasma, Xfce, Cinnamon, etc.).
- **Spotify Premium** for playback. Free accounts can browse, but Spotifast cannot play music through librespot without Premium.

## Install a specific version

```bash
curl -fsSL https://raw.githubusercontent.com/imdonix/spotifast-install/main/install.sh | bash -s -- --version 0.14.1
```

AppImage checksums are published for recent releases (v0.14.0 and newer). Older releases can still be used with the official `.deb`, `.rpm`, or Flatpak packages from the [download page](https://spotifast.rocks/download/).

## Manual and development use

```bash
git clone https://github.com/imdonix/spotifast-install.git
cd spotifast-install
./install.sh
```

Useful options:

```text
--version X.Y.Z     install a specific release
--force             continue when the glibc check fails
--uninstall         remove Spotifast, keep settings
--uninstall --purge remove Spotifast and all of its data
--help              show help
```

## Repository layout

| File | Purpose |
| --- | --- |
| [`install.sh`](install.sh) | Installs, updates the integration, and uninstalls Spotifast. |
| [`lib/spotifast-launcher`](lib/spotifast-launcher) | Starts the background update check, then launches the AppImage. |
| [`lib/spotifast-update`](lib/spotifast-update) | Verifies and installs signed GitHub releases. |
| [`lib/spotifast.svg`](lib/spotifast.svg) | Fallback icon used if the AppImage's icon cannot be extracted. |

## Troubleshooting

**Spotifast does not appear in the menu.**
Log out and back in, or run:

```bash
update-desktop-database ~/.local/share/applications
gtk-update-icon-cache -f -t ~/.local/share/icons/hicolor
```

**The app does not start.**
Check the AppImage directly:

```bash
~/.local/opt/spotifast/Spotifast.AppImage --version
```

If that reports a FUSE error, force the extraction fallback:

```bash
echo extract > ~/.local/opt/spotifast/run-mode
```

Then launch Spotifast again. The installer normally detects this automatically.

**Updates fail.**
Run the updater in the terminal and read the log:

```bash
spotifast-update --foreground
cat ~/.local/state/spotifast-install/update.log
```

**I use Ubuntu 22.04.**
Spotifast's current Linux builds need glibc 2.39. Upgrade to Ubuntu 24.04 or newer, or use an older Spotifast release from the official releases page.

**I do not want automatic update checks.**
Remove the updater or make the launcher skip it:

```bash
rm ~/.local/opt/spotifast/spotifast-update
```

Spotifast's own update checker is separate and can be changed in the app's settings.

## Security

- The installer runs as your user and never calls `sudo`.
- The AppImage and its checksum files are downloaded only from the official `crmne/spotifast` GitHub releases.
- The release checksum file is verified against Spotifast's pinned Ed25519 public key.
- The AppImage is verified against that checksum before it replaces anything.
- The new AppImage must pass a `--version` smoke test before installation.
- The launcher and updater are plain Bash scripts with no third-party runtime dependencies.

Review [install.sh](install.sh), the [launcher](lib/spotifast-launcher), and the [updater](lib/spotifast-update) before running it. When the installer is piped, it downloads the two small helper scripts from this repository; the AppImage itself still comes only from the official `crmne/spotifast` releases and is signature-checked.

## License and disclaimer

This installer is released under the [MIT License](LICENSE).

Spotifast is Copyright © Carmine Paolino and is licensed under the MIT License. Spotify is a trademark of Spotify AB. This project is unofficial and is not affiliated with or endorsed by Spotifast or Spotify.

**Keyring note:** Spotify sign-ins are kept in your desktop's Secret Service (GNOME Keyring, KWallet, etc.), not only in the files above. To revoke them, open Spotifast, go to **Settings**, and choose **Sign out** before uninstalling. The uninstaller intentionally does not delete keyring entries on your behalf.
