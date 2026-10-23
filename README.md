<p align="center">
  <img src="https://raw.githubusercontent.com/crmne/spotifast/main/docs/assets/images/logo.svg" alt="Spotifast logo" width="96">
</p>

<h1 align="center">Spotifast Linux Installer</h1>

> **What is Spotifast?**
> [Spotifast](https://spotifast.rocks/) is a lightweight, native Spotify client for Linux, macOS, and Windows, written in Rust. It starts in well under a second, typically uses 100–250 MB of RAM, and supports Spotify Connect, local files, MPRIS, a Winamp-style mini player, and MilkDrop. Playback requires **Spotify Premium**.
>
> Spotifast is an independent project by Carmine Paolino: [spotifast.rocks](https://spotifast.rocks/) · [GitHub](https://github.com/crmne/spotifast). It is not affiliated with or endorsed by Spotify AB.
>
> **This repository is not Spotifast.** It is an unofficial installer that makes the official Linux build feel like a normal desktop app.

[![Platform: Linux](https://img.shields.io/badge/platform-Linux-2b2b2b?logo=linux&logoColor=white)](TECHNICAL.md#requirements)
[![Installer: Bash](https://img.shields.io/badge/installer-Bash-4eaa25?logo=gnubash&logoColor=white)](#install)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

<p align="center">
  <a href="https://spotifast.rocks/">
    <img src="https://raw.githubusercontent.com/crmne/spotifast/main/docs/screenshot.png" alt="Spotifast screenshot" width="760">
  </a>
</p>

---

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
