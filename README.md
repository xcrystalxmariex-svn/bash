# bash

Shell utilities for Termux and headless Ubuntu / Linux.

| Script | Purpose |
|--------|---------|
| `apk_builder.sh` | Universal headless Android APK builder (Ubuntu & Termux). Formerly `setup_builder.sh`. |
| `codespace.sh` | Termux Codespace CLI — create / list / SSH into GitHub Codespaces |
| `deploy_daytona.sh` | Interactive Dockur / Tiny11 Windows KVM deployer (local Docker) |
| `opencode_telegram_deploy.sh` | OpenCode agent + Telegram bot bridge (auto-restart watchdog) |
| `storage-clean.sh` | Interactive Termux `~/storage` cleaner (Downloads, APKs, thumbnails, large files) |
| `set-git-shorthand.sh` | Adds `gh:` → `https://github.com/` URL rewrite (global + local) |
| `setup-git-workspace.sh` | Scoped Git workspace with author, PAT credential store, and `includeIf` |

---

## apk_builder.sh
```bash
chmod +x apk_builder.sh
./apk_builder.sh
```
Supports git clone, local path, or zip; detects SDK/flavors; streams live Gradle output.

## codespace.sh
```bash
chmod +x codespace.sh
./codespace.sh
```
Requires `gh` and `openssh`. Authenticates with GitHub if needed (`codespace` scope).

## deploy_daytona.sh
```bash
chmod +x deploy_daytona.sh
./deploy_daytona.sh
```
Interactive local Docker deploy of `dockur/windows` (Tiny11 or Win10 LTSC) with Steam game profile, networking options (localhost / public IP / Cloudflare tunnel / X11), and OEM install.bat.

## opencode_telegram_deploy.sh
```bash
chmod +x opencode_telegram_deploy.sh
./opencode_telegram_deploy.sh
cd ~/opencode-telegram-agent && ./start.sh
```
Installs dependencies, creates a venv, configures Telegram bot token + OpenCode port, writes a hardened bridge with regenerate support, and a `start.sh` that runs OpenCode under a 15-second auto-restart watchdog.

## storage-clean.sh
```bash
chmod +x storage-clean.sh
./storage-clean.sh
```
Termux-oriented interactive cleaner for shared Android storage: stale archives in Downloads, leftover APK/AAB/DEB files, `.thumbnails` / trash, and a top-15 largest-files listing.

## set-git-shorthand.sh
```bash
chmod +x set-git-shorthand.sh
./set-git-shorthand.sh
```
Configures `git config --global url."https://github.com/".insteadOf "gh:"` so you can clone with `git clone gh:user/repo`.

## setup-git-workspace.sh
```bash
chmod +x setup-git-workspace.sh
./setup-git-workspace.sh
```
Creates a scoped Git workspace (default under `~/storage/shared/Termux/git_repos`), writes author + credential helper + PAT store (mode 600), and registers a conditional `includeIf` + `safe.directory` entries so Android/FAT permission noise is handled.
