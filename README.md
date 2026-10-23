<p align="center">
  <img src="https://raw.githubusercontent.com/crmne/spotifast/main/docs/assets/images/logo.svg" alt="Spotifast logo" width="96">
</p>

<h1 align="center">Spotifast Installer</h1>

> **What is Spotifast?**
> [Spotifast](https://spotifast.rocks/) is a lightweight, native Spotify client for Linux, macOS, and Windows, written in Rust. It starts in well under a second, typically uses 100–250 MB of RAM, and supports Spotify Connect, local files, MPRIS, a Winamp-style mini player, and MilkDrop. Playback requires **Spotify Premium**.
>
> Spotifast is an independent project by Carmine Paolino: [spotifast.rocks](https://spotifast.rocks/) · [GitHub](https://github.com/crmne/spotifast). It is not affiliated with or endorsed by Spotify AB.
>
> **This repository is not Spotifast.** It is an unofficial installer that makes the official desktop builds feel like normal apps.

[![Platforms: Linux, macOS, Windows](https://img.shields.io/badge/platforms-Linux%20%7C%20macOS%20%7C%20Windows-2b2b2b?logo=linux&logoColor=white)](#install)
[![Installer: Bash + PowerShell](https://img.shields.io/badge/installer-Bash%20%2B%20PowerShell-4eaa25?logo=gnubash&logoColor=white)](#install)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

<p align="center">
  <a href="https://spotifast.rocks/">
    <img src="https://raw.githubusercontent.com/crmne/spotifast/main/docs/screenshot.png" alt="Spotifast screenshot" width="760">
  </a>
</p>

---

## Install

**Linux / macOS**

```bash
curl -fsSL https://raw.githubusercontent.com/imdonix/spotifast-install/main/install.sh | bash
```

**Windows (PowerShell)**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/imdonix/spotifast-install/main/install.ps1 | iex"
```

Or download [`install.cmd`](https://raw.githubusercontent.com/imdonix/spotifast-install/main/install.cmd) and run it.

No `sudo` or administrator rights are needed. The installer downloads the official release, verifies it, and adds the normal app menu/launcher entry. Open **Spotifast** and sign in with Spotify.

## Update

| Platform | Automatic | Manual |
| --- | --- | --- |
| Linux | Checked in the background when Spotifast starts | `spotifast-update` |
| macOS | Built into Spotifast | `~/.local/bin/spotifast-update` |
| Windows | Built into Spotifast | `%LOCALAPPDATA%\Spotifast\bin\spotifast-update.cmd` |

On Linux, right-click the app icon and choose **Check for Updates**. On Windows, the installer also adds a **Check for Updates** Start menu shortcut.

## Uninstall

**Linux / macOS**

```bash
curl -fsSL https://raw.githubusercontent.com/imdonix/spotifast-install/main/install.sh | bash -s -- --uninstall
```

**Windows (PowerShell)**

```powershell
$installer = "$env:TEMP\spotifast-install.ps1"
irm https://raw.githubusercontent.com/imdonix/spotifast-install/main/install.ps1 -OutFile $installer
& $installer -Uninstall
```

This keeps settings and local state. Add `--purge` (Linux/macOS) or `-Purge` (Windows) to remove local settings and caches too. The system keyring, macOS Keychain, and Windows Credential Manager are not touched.

## Technical details

Requirements, verification details, install paths, update modes, troubleshooting, and development notes are in **[TECHNICAL.md](TECHNICAL.md)**.

MIT licensed. Spotifast is by Carmine Paolino; this project is unofficial and not affiliated with Spotifast or Spotify.
