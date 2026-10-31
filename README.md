<p align="center">
  <img src="https://raw.githubusercontent.com/crmne/spotifast/main/docs/assets/images/logo.svg" alt="Spotifast logo" width="96">
</p>

<h1 align="center">Spotifast Installer</h1>

> **What is Spotifast?**
> [Spotifast](https://spotifast.rocks/) is a lightweight, native Spotify client for Linux and macOS, written in Rust. It starts in well under a second, typically uses 100–250 MB of RAM, and supports Spotify Connect, local files, MPRIS, a Winamp-style mini player, and MilkDrop. Playback requires **Spotify Premium**.
>
> Spotifast is an independent project by Carmine Paolino: [spotifast.rocks](https://spotifast.rocks/) · [GitHub](https://github.com/crmne/spotifast). It is not affiliated with or endorsed by Spotify AB.
>
> **This repository is not Spotifast.** It is an unofficial installer that makes the official desktop builds feel like normal apps.

[![Platforms: Linux, macOS](https://img.shields.io/badge/platforms-Linux%20%7C%20macOS-2b2b2b?logo=linux&logoColor=white)](#install)
[![Installer: Bash](https://img.shields.io/badge/installer-Bash-4eaa25?logo=gnubash&logoColor=white)](#install)
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

No `sudo` is needed. The installer downloads the official release, verifies it, and adds the normal app integration.

## Update

Spotifast updates itself from inside the app on both Linux and macOS. Use the green update button, or check manually from **Settings → About** (or the Spotifast menu on macOS). Updates keep your settings and sign-ins.

- **Linux:** the AppImage must stay in a folder you own and can write to. This installer uses `~/.local/opt/spotifast`, so it qualifies.
- **macOS:** Spotifast must stay in your Applications folder. This installer uses `~/Applications`.
- **Versions 0.13.3 and older** do not self-update. Re-run the installer once to move to a current release.

Earlier versions of this installer added a `spotifast-update` command. It is no longer installed; use the in-app updater instead.

To repair the desktop integration or install a specific release, re-run the install command.

## Uninstall

**Linux / macOS**

```bash
curl -fsSL https://raw.githubusercontent.com/imdonix/spotifast-install/main/install.sh | bash -s -- --uninstall
```

This keeps settings and local state. Add `--purge` to remove local settings and caches too. The system keyring and macOS Keychain are not touched.

## Technical details

Requirements, verification details, install paths, update behavior, troubleshooting, and development notes are in **[TECHNICAL.md](TECHNICAL.md)**.

MIT licensed. Spotifast is by Carmine Paolino; this project is unofficial and not affiliated with Spotifast or Spotify.
