# bash

Shell utilities for Termux and headless Ubuntu.

| Script | Purpose |
|--------|---------|
| `setup_builder.sh` | Abyssal Terminal — universal headless Android APK builder (Ubuntu & Termux) |
| `codespace.sh` | Termux Codespace CLI — create / list / SSH into GitHub Codespaces |

## setup_builder.sh
```bash
chmod +x setup_builder.sh
./setup_builder.sh
```
Supports git clone, local path, or zip; detects SDK/flavors; streams live Gradle output.

## codespace.sh
```bash
chmod +x codespace.sh
./codespace.sh
```
Requires `gh` and `openssh`. Authenticates with GitHub if needed (`codespace` scope).
