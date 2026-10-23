# Spotifast Installer — Technical Notes

This is the detailed companion to the short [README](README.md). It covers what the installer changes on each platform, how updates work, requirements, paths, troubleshooting, and security.

## Platform support

| Platform | Entry point | Official package used |
| --- | --- | --- |
| Linux x86_64 / aarch64 | [`install.sh`](install.sh) | AppImage |
| macOS Apple Silicon / Intel | [`install.sh`](install.sh) → [`lib/install-macos.sh`](lib/install-macos.sh) | Universal DMG |
| Windows x64 / ARM64 | [`install.ps1`](install.ps1) or [`install.cmd`](install.cmd) | Per-user MSI |

The installer is unofficial. It always downloads the app from the official [`crmne/spotifast`](https://github.com/crmne/spotifast/releases) GitHub releases.

## What the installer does

### Linux

1. Detects the CPU architecture and checks the glibc version.
2. Finds the latest official release.
3. Downloads the AppImage plus `checksums.txt` and `checksums.txt.sig`.
4. Verifies the **Ed25519 signature** of the checksums with Spotifast's pinned public key, then the **SHA-256 checksum** of the AppImage.
5. Tests that the AppImage can run before replacing an existing installation.
6. Installs the app, launcher, updater, desktop entry, and icon.
7. Registers `spotifast.desktop` for `spotify:` links if no handler is set yet.

If FUSE is unavailable, the launcher uses the AppImage's `--appimage-extract-and-run` fallback.

### macOS

1. Finds the latest official release and downloads the universal DMG.
2. Verifies the published **SHA-256 checksum**. If OpenSSL 3 is available, it also verifies the Ed25519 checksum signature.
3. Mounts the DMG read-only.
4. Verifies the app with `codesign --verify --deep --strict` and Gatekeeper's `spctl --assess`.
5. Checks the bundle's `CFBundleShortVersionString` against the release version.
6. Copies `Spotifast.app` to `~/Applications`, replacing any previous copy.
7. Registers it with LaunchServices and installs `~/.local/bin/spotifast` (CLI wrapper) and `~/.local/bin/spotifast-update`.

The macOS app is notarized by Apple. The installer never bypasses the code-signature check; `--force` only bypasses a failed Gatekeeper assessment when you explicitly ask.

### Windows

1. Detects Windows 10/11 and the CPU architecture (x64 or ARM64).
2. Finds the latest official release and downloads the matching MSI.
3. Verifies the published **SHA-256 checksum**. If OpenSSL 3 is available, it also verifies the Ed25519 checksum signature.
4. Removes the Mark of the Web from the MSI and runs it per-user with `msiexec /qn /norestart`.
5. Installs a manual updater at `%LOCALAPPDATA%\Spotifast\bin\spotifast-update.ps1` and a `.cmd` wrapper.
6. Adds a **Check for Updates** shortcut to the Spotifast Start menu folder.

The MSI is not publisher-signed with a Windows code-signing certificate, so SmartScreen may still show a warning. The installer verifies the published checksum before running it.

## Where things go

### Linux

| What | Path |
| --- | --- |
| AppImage | `~/.local/opt/spotifast/Spotifast.AppImage` |
| Launcher | `~/.local/bin/spotifast` |
| Updater | `~/.local/bin/spotifast-update` |
| Desktop entry | `~/.local/share/applications/spotifast.desktop` |
| Icon | `~/.local/share/icons/hicolor/scalable/apps/spotifast.svg` |
| Update log | `~/.local/state/spotifast-install/update.log` |
| Settings and sign-ins | `~/.config/spotifast` and the system keyring |

`XDG_BIN_HOME`, `XDG_DATA_HOME`, `XDG_STATE_HOME`, and `SPOTIFAST_INSTALL_DIR` are respected.

### macOS

| What | Path |
| --- | --- |
| App | `~/Applications/Spotifast.app` |
| CLI | `~/.local/bin/spotifast` |
| Updater | `~/.local/bin/spotifast-update` |
| Update log | `~/Library/Logs/spotifast-install/update.log` |
| Installer state | `~/Library/Application Support/spotifast-install` |
| Settings, state, logs | `~/Library/Application Support/me.paolino.spotifast` |
| Caches | `~/Library/Caches/me.paolino.spotifast` |
| Sign-ins | macOS Keychain |

`SPOTIFAST_APP_DIR` and `SPOTIFAST_BIN_DIR` are respected.

### Windows

| What | Path |
| --- | --- |
| App | `%LOCALAPPDATA%\Programs\Spotifast` |
| Updater | `%LOCALAPPDATA%\Spotifast\bin\spotifast-update.cmd` |
| Updater script | `%LOCALAPPDATA%\Spotifast\bin\spotifast-update.ps1` |
| Update shortcut | `%APPDATA%\Microsoft\Windows\Start Menu\Programs\Spotifast\Check for Updates.lnk` |
| Installer state and MSI log | `%LOCALAPPDATA%\Spotifast\installer` |
| Settings | `%APPDATA%\paolino\spotifast\config` |
| State and logs | `%LOCALAPPDATA%\paolino\spotifast\data` |
| Cache | `%LOCALAPPDATA%\paolino\spotifast\cache` |
| Sign-ins | Windows Credential Manager |

## Updates

### Linux

**Recommended: background updates.** The app-menu launcher starts `spotifast-update --auto` as a detached background process, then opens Spotifast immediately. It checks at most once every 24 hours. If a newer release exists, it downloads and verifies it, replaces the AppImage in place, and sends a desktop notification. The new version is used the next time Spotifast starts.

```bash
spotifast-update            # small GUI if zenity is available, terminal otherwise
spotifast-update --gui      # force the zenity dialogs
spotifast-update --check    # only report whether an update is available
spotifast-update --foreground
                            # check and update in the terminal
```

Or right-click the Spotifast icon in the application menu and choose **Check for Updates**.

### macOS

Spotifast updates itself from its own interface. For a manual check or forced install:

```bash
~/.local/bin/spotifast-update
~/.local/bin/spotifast-update --check
~/.local/bin/spotifast-update --version X.Y.Z
```

The updater downloads the universal DMG, verifies the checksum, checks the app signature, and replaces `~/Applications/Spotifast.app`. The old app is left untouched if verification fails. Restart Spotifast after an update.

### Windows

Spotifast updates itself from its own interface. The installer also provides a manual fallback:

```text
%LOCALAPPDATA%\Spotifast\bin\spotifast-update.cmd
```

Or use the **Check for Updates** Start menu shortcut. The updater downloads the latest MSI, verifies the checksum, and runs the per-user MSI upgrade. The MSI keeps one installation and replaces it transactionally.

The updater replaces only the application package. If this repository changes the launcher, updater, or desktop integration, re-run the install command to refresh those files.

## Requirements

### Linux

- **Linux** on `x86_64` or `aarch64`.
- **glibc 2.39 or newer**: Ubuntu 24.04+, Linux Mint 22+, Debian 13+, Fedora 41+, or newer. Spotifast's current Linux builds will not start on Ubuntu 22.04.
- `curl`, `sha256sum`, `awk`, and `sort` (standard on Ubuntu).
- `openssl` 3+ for the Ed25519 signature check. Without it, SHA-256 is still verified.
- Optional: `zenity` for the update GUI, `notify-send` for notifications, FUSE for the fastest AppImage startup.
- A desktop environment that follows the XDG desktop-entry and icon specifications.

### macOS

- A current macOS release with the standard `hdiutil`, `codesign`, `spctl`, and LaunchServices tools.
- The official build is universal: Apple Silicon and Intel are both supported.
- `curl`, `shasum`, `ditto`, and `PlistBuddy` (all included with macOS).
- `openssl` 3+ is optional; without it, SHA-256 and the Apple code signature are still verified.

### Windows

- **Windows 10 or newer**, 64-bit x64 or ARM64.
- **PowerShell 5.1 or newer** (included with Windows 10/11).
- No administrator rights; the Spotifast MSI installs per-user.
- `openssl` 3+ is optional; without it, SHA-256 is still verified.

### All platforms

- **Spotify Premium** for playback. Free accounts can browse, but Spotifast cannot play music through librespot without Premium.

## Install a specific version

```bash
# Linux / macOS
curl -fsSL https://raw.githubusercontent.com/imdonix/spotifast-install/main/install.sh | bash -s -- --version 0.14.1
```

```powershell
# Windows, from a downloaded install.ps1
.\install.ps1 -Version 0.14.1
```

AppImage checksums are published for recent releases (v0.14.0 and newer). Older releases can still be used with the official `.deb`, `.rpm`, or Flatpak packages from the [download page](https://spotifast.rocks/download/).

## Manual and development use

```bash
git clone https://github.com/imdonix/spotifast-install.git
cd spotifast-install
./install.sh          # Linux or macOS
```

On Windows:

```powershell
git clone https://github.com/imdonix/spotifast-install.git
cd spotifast-install
.\install.ps1
```

Useful options:

```text
--version X.Y.Z     install a specific release (Linux/macOS)
--force             continue when the platform check fails (Linux glibc, macOS Gatekeeper)
--uninstall         remove Spotifast, keep settings
--uninstall --purge remove Spotifast and local app data
--help              show help
```

Windows uses PowerShell switches: `-Version`, `-Force`, `-Uninstall`, `-Purge`, `-Update`, `-Check`, `-Help`.

## Repository layout

| File | Purpose |
| --- | --- |
| [`install.sh`](install.sh) | Linux/macOS entry point and Linux installer. |
| [`install.ps1`](install.ps1) | Windows installer, updater, and uninstaller. |
| [`install.cmd`](install.cmd) | Windows convenience wrapper for running `install.ps1`. |
| [`lib/install-macos.sh`](lib/install-macos.sh) | macOS app-bundle installer/updater. |
| [`lib/spotifast-launcher`](lib/spotifast-launcher) | Linux launcher that starts the background update check. |
| [`lib/spotifast-update`](lib/spotifast-update) | Linux verifier and updater. |
| [`lib/spotifast.svg`](lib/spotifast.svg) | Linux fallback icon. |

## Troubleshooting

### Linux

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

Then launch Spotifast again.

**Updates fail.**
Run the updater in the terminal and read the log:

```bash
spotifast-update --foreground
cat ~/.local/state/spotifast-install/update.log
```

**I use Ubuntu 22.04.**
Spotifast's current Linux builds need glibc 2.39. Upgrade to Ubuntu 24.04 or newer, or use an older Spotifast release from the official releases page.

### macOS

**The app is blocked by Gatekeeper.**
The installer already verifies the app signature. If macOS still blocks it, open **System Settings → Privacy & Security** and choose **Open Anyway**, or clear the download quarantine:

```bash
xattr -dr com.apple.quarantine ~/Applications/Spotifast.app
open ~/Applications/Spotifast.app
```

**The installer says Gatekeeper could not assess the app.**
Rerun with `--force` only if you trust the release. The code signature is still required; `--force` does not bypass it.

**The `spotifast` or `spotifast-update` command is not found.**
`~/.local/bin` may not be on your `PATH`. Use the full path or add it:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

**Updates fail.**
Run the updater in the terminal and read the log:

```bash
~/.local/bin/spotifast-update
cat ~/Library/Logs/spotifast-install/update.log
```

### Windows

**PowerShell blocks the script.**
Use the one-line command with `-ExecutionPolicy Bypass`, or run a downloaded copy:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

**SmartScreen warns about the MSI.**
The Spotifast MSI is not publisher-signed. The installer verifies the published SHA-256 checksum before running it. Choose **More info → Run anyway** if Windows asks.

**The MSI install fails.**
Read the MSI log:

```text
%LOCALAPPDATA%\Spotifast\installer\msiexec.log
```

**The updater command is not found.**
Use the full path or the Start menu shortcut:

```text
%LOCALAPPDATA%\Spotifast\bin\spotifast-update.cmd
```

**I do not want automatic update checks.**
Linux: remove `~/.local/opt/spotifast/spotifast-update`. macOS/Windows: Spotifast's own update checker can be changed in the app's settings; remove the manual updater files if you do not want them.

## Security

- The installers run as your user. Linux and macOS install per-user; the Windows MSI is also per-user. No `sudo` or administrator prompt is expected.
- The application package is downloaded only from the official `crmne/spotifast` GitHub releases.
- Linux verifies the release checksum file against Spotifast's pinned Ed25519 public key, verifies the AppImage's SHA-256, and runs a `--version` smoke test.
- macOS verifies the DMG's SHA-256, the app's Apple code signature, and Gatekeeper notarization. The Ed25519 checksum signature is also checked when OpenSSL 3 is available.
- Windows verifies the MSI's SHA-256 and, when OpenSSL 3 is available, the Ed25519 checksum signature. The MSI itself is not Authenticode-signed by the publisher.
- The Linux launcher/updater and the Windows updater are plain scripts. When an installer is piped, it downloads its small helper scripts from this repository; the app package still comes only from the official Spotifast releases.

Review [install.sh](install.sh), [install.ps1](install.ps1), and the helpers in [`lib/`](lib/) before running them.

## License and disclaimer

This installer is released under the [MIT License](LICENSE).

Spotifast is Copyright © Carmine Paolino and is licensed under the MIT License. Spotify is a trademark of Spotify AB. This project is unofficial and is not affiliated with or endorsed by Spotifast or Spotify.

**Credential note:** Spotify sign-ins are kept in the platform credential store: Secret Service on Linux, Keychain on macOS, and Credential Manager on Windows. To revoke them, open Spotifast, go to **Settings**, and choose **Sign out** before uninstalling. The uninstallers intentionally do not delete credential-store entries on your behalf.
