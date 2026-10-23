# Spotifast Linux Installer

> **What is Spotifast?** [Spotifast](https://spotifast.rocks/) is a lightweight, native Spotify client for Linux, macOS, and Windows, written in Rust. Playback requires **Spotify Premium**.
>
> This repository is an unofficial, per-user Linux installer for the official Spotifast AppImage. It is not the Spotifast project.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/imdonix/spotifast-install/main/install.sh | bash
```

No `sudo`. The installer downloads the official AppImage, verifies it, and adds the application-menu entry and icon. Open **Spotifast** from the menu and sign in with Spotify.

## Update

Updates are checked in the background once a day when Spotifast starts. To check or update now:

```bash
spotifast-update
```

Or right-click the Spotifast icon in the application menu and choose **Check for Updates**.

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/imdonix/spotifast-install/main/install.sh | bash -s -- --uninstall
```

This keeps your settings and local state. Add `--purge` to remove local settings and caches too. The desktop keyring is not touched.

## Technical details

Requirements, verification details, install paths, update modes, troubleshooting, and development notes are in **[TECHNICAL.md](TECHNICAL.md)**.

MIT licensed. Spotifast is by Carmine Paolino; this project is unofficial and not affiliated with Spotifast or Spotify.
