#!/usr/bin/env bash
# ==============================================================================
# Dockur / Tiny11 Interactive Universal Deployer (Network-Adaptive)
# Fixed & hardened for xcrystalxmariex-svn/bash
# ==============================================================================
set -euo pipefail

# ANSI Color Codes (fixed)
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

clear
echo -e "${CYAN}======================================================${NC}"
echo -e "${CYAN}    Automated Windows KVM / Dockur Instance Setup     ${NC}"
echo -e "${CYAN}======================================================${NC}\n"

# 1. Environment & Package Manager Detection
detect_pkg_mgr() {
    if command -v apt-get >/dev/null 2>&1; then echo "apt"
    elif command -v apk >/dev/null 2>&1; then echo "apk"
    elif command -v pkg >/dev/null 2>&1; then echo "pkg"
    elif command -v dnf >/dev/null 2>&1; then echo "dnf"
    elif command -v pacman >/dev/null 2>&1; then echo "pacman"
    else echo "unknown"; fi
}
PKG_MGR=$(detect_pkg_mgr)

echo -e "${YELLOW}[*] Detecting runtime dependencies...${NC}"
install_dep() {
    local tool=$1
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo -e "${YELLOW}[-] Installing missing dependency: $tool...${NC}"
        case "$PKG_MGR" in
            apt)  sudo apt-get update -y && sudo apt-get install -y "$tool" docker-compose-plugin ;;
            apk)  sudo apk add --no-cache "$tool" docker-cli-compose ;;
            pkg)  pkg install -y "$tool" ;;
            dnf)  sudo dnf install -y "$tool" docker-compose-plugin ;;
            pacman) sudo pacman -Sy --noconfirm "$tool" docker-compose ;;
            *) echo -e "${RED}[!] Ensure $tool is installed manually.${NC}" ;;
        esac
    fi
}
for req in curl docker; do install_dep "$req"; done

# 2. Hardware Virtualization (KVM) Check
KVM_DEV=""
KVM_ENABLED="Y"
if [ -e /dev/kvm ] && [ -w /dev/kvm ]; then
    KVM_DEV="--device=/dev/kvm"
elif [ -e /dev/kvm ]; then
    sudo chmod 666 /dev/kvm 2>/dev/null || true
    KVM_DEV="--device=/dev/kvm"
else
    KVM_ENABLED="N"
    echo -e "${YELLOW}[!] /dev/kvm not available — software emulation will be used (slower).${NC}"
fi

# 3. Interactive Specification Configuration
echo -e "\n${CYAN}--- Hardware & Instance Configuration ---${NC}"
read -rp "RAM Allocation in GB [Default: 8]: " INPUT_RAM
RAM_SIZE="${INPUT_RAM:-8}G"

SYSTEM_CORES=$(nproc 2>/dev/null || echo 2)
read -rp "CPU Cores to assign (Detected host cores: $SYSTEM_CORES) [Default: 2]: " INPUT_CORES
CPU_CORES="${INPUT_CORES:-2}"

read -rp "Virtual HDD Size in GB [Default: 160]: " INPUT_DISK
DISK_SIZE="${INPUT_DISK:-160}G"

# 4. Interactive Networking Routing Setup
echo -e "\n${CYAN}--- Networking Routing & Domain Access ---${NC}"
echo "1) Localhost Bind Only (Standard)"
echo "2) Public Network Interface IP (Explicit WAN / Node Address)"
echo "3) Cloudflare Instant Tunnel (Zero-Trust Subdomain Exposure)"
echo "4) X11 Direct Server Socket Forwarding"
read -rp "Select routing style [1-4, Default: 1]: " NET_CHOICE
NET_CHOICE="${NET_CHOICE:-1}"

DOCKER_PORTS=""
X11_ENV=""
X11_VOLUMES=""
CF_TUNNEL_ENABLED="N"
TARGET_IP="127.0.0.1"

case "$NET_CHOICE" in
    1)
        DOCKER_PORTS="-p 8006:8006 -p 3389:3389/tcp -p 3389:3389/udp"
        TARGET_IP="127.0.0.1"
        ;;
    2)
        read -rp "Enter target interface IP or Public Node Address: " PUBLIC_IP
        if [ -z "$PUBLIC_IP" ]; then
            echo -e "${RED}[!] Public IP required for option 2. Aborting.${NC}"
            exit 1
        fi
        DOCKER_PORTS="-p ${PUBLIC_IP}:8006:8006 -p ${PUBLIC_IP}:3389:3389/tcp -p ${PUBLIC_IP}:3389:3389/udp"
        TARGET_IP="$PUBLIC_IP"
        ;;
    3)
        CF_TUNNEL_ENABLED="Y"
        DOCKER_PORTS="-p 8006:8006 -p 3389:3389/tcp -p 3389:3389/udp"
        read -rp "Enter your Cloudflare Tunnel Token (Leave blank for ephemeral quick-tunnel): " CF_TOKEN
        TARGET_IP="Cloudflare Edge Domain"
        ;;
    4)
        DOCKER_PORTS="-p 8006:8006"
        X11_ENV="-e DISPLAY=${DISPLAY:-:0}"
        X11_VOLUMES="-v /tmp/.X11-unix:/tmp/.X11-unix:ro"
        TARGET_IP="Local XServer Display Socket"
        ;;
    *)
        echo -e "${RED}[!] Invalid selection. Defaulting to localhost.${NC}"
        DOCKER_PORTS="-p 8006:8006 -p 3389:3389/tcp -p 3389:3389/udp"
        ;;
esac

# 5. OS Selection
echo -e "\n${CYAN}--- Select OS Image Layer ---${NC}"
echo "1) Tiny11 (Stripped Windows 11 - Recommended)"
echo "2) Windows 10 LTSC (10l)"
read -rp "Select option [1-2, Default: 1]: " OS_CHOICE
OS_CHOICE="${OS_CHOICE:-1}"

if [ "$OS_CHOICE" -eq 2 ]; then
    WIN_VERSION="10l"
else
    WIN_VERSION="tiny11"
fi

# 6. Game Target Selection
echo -e "\n${CYAN}--- Select Target Game Profile ---${NC}"
echo "1) Brawlhalla (App ID: 291550)"
echo "2) The Sims 4 (App ID: 1222670)"
read -rp "Select option [1-2, Default: 1]: " GAME_CHOICE
GAME_CHOICE="${GAME_CHOICE:-1}"

if [ "$GAME_CHOICE" -eq 2 ]; then
    CONTAINER_NAME="windows_sims"
    STEAM_APP_ID="1222670"
    LAUNCH_FLAGS=""
    GAME_LABEL="The Sims 4"
else
    CONTAINER_NAME="windows_brawlhalla"
    STEAM_APP_ID="291550"
    LAUNCH_FLAGS="-noeac -nogl -framebyframe"
    GAME_LABEL="Brawlhalla"
fi

# 7. Write Custom Windows Initialization Script (install.bat for Dockur OEM)
mkdir -p ./config
cat << 'EOF' > ./config/install.bat
@echo off
setlocal EnableDelayedExpansion

echo [OEM] Starting post-install Steam + game shortcut setup...

set "STEAM_URL=https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe"
set "STEAM_INSTALLER=%TEMP%\SteamSetup.exe"
set "STEAM_PATH=C:\Program Files (x86)\Steam\steam.exe"
set "DESKTOP=%USERPROFILE%\Desktop"
set "SHORTCUT=%DESKTOP%\Launch Game.lnk"

:: Download Steam installer
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "try { Invoke-WebRequest -Uri '%STEAM_URL%' -OutFile '%STEAM_INSTALLER%' -UseBasicParsing } catch { exit 1 }"
if errorlevel 1 (
  echo [OEM] Failed to download SteamSetup.exe
  exit /b 1
)

:: Silent install
"%STEAM_INSTALLER%" /S
timeout /t 15 /nobreak >nul

:: Create desktop shortcut that launches the selected game
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$WshShell = New-Object -ComObject WScript.Shell; ^
   $Shortcut = $WshShell.CreateShortcut('%SHORTCUT%'); ^
   $Shortcut.TargetPath = '%STEAM_PATH%'; ^
   $Shortcut.Arguments = '-applaunch __STEAM_APP_ID__ __LAUNCH_FLAGS__'; ^
   $Shortcut.WorkingDirectory = 'C:\Program Files (x86)\Steam'; ^
   $Shortcut.Save()"

echo [OEM] Steam installed and desktop shortcut created.
endlocal
EOF

# Inject the concrete App ID and flags into the bat
sed -i "s/__STEAM_APP_ID__/${STEAM_APP_ID}/g" ./config/install.bat
sed -i "s/__LAUNCH_FLAGS__/${LAUNCH_FLAGS}/g" ./config/install.bat

# 8. Deploying Core Docker Container Architecture
echo -e "\n${YELLOW}[*] Spawning Windows virtualization base stack...${NC}"
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

AUDIO_DEV=""
if [ -e /dev/snd ]; then
    AUDIO_DEV="--device=/dev/snd"
fi

docker run -d \
    --name "$CONTAINER_NAME" \
    --privileged \
    --cap-add=NET_ADMIN \
    -e VERSION="$WIN_VERSION" \
    -e RAM_SIZE="$RAM_SIZE" \
    -e CPU_CORES="$CPU_CORES" \
    -e DISK_SIZE="$DISK_SIZE" \
    -e KVM="$KVM_ENABLED" \
    -e HV="Y" \
    $DOCKER_PORTS \
    $X11_ENV \
    $X11_VOLUMES \
    -v "$(pwd)/config:/oem" \
    $KVM_DEV \
    $AUDIO_DEV \
    --shm-size="2gb" \
    --restart unless-stopped \
    dockur/windows

# 9. Optional Sidecar: Cloudflare Tunnel
if [ "$CF_TUNNEL_ENABLED" = "Y" ]; then
    echo -e "${YELLOW}[*] Spinning up Cloudflare Zero-Trust Edge tunnel...${NC}"
    docker rm -f "${CONTAINER_NAME}_tunnel" >/dev/null 2>&1 || true

    if [ -z "${CF_TOKEN:-}" ]; then
        docker run -d --name "${CONTAINER_NAME}_tunnel" --network="host" \
            cloudflare/cloudflared:latest tunnel --url http://127.0.0.1:8006
        echo -e "${YELLOW}[!] Ephemeral tunnel active. Grab the URL from: docker logs ${CONTAINER_NAME}_tunnel${NC}"
    else
        docker run -d --name "${CONTAINER_NAME}_tunnel" --network="host" \
            cloudflare/cloudflared:latest tunnel --no-autoupdate run --token "$CF_TOKEN"
    fi
fi

echo -e "\n${GREEN}======================================================${NC}"
echo -e "${GREEN}🚀 Deployment Initialized${NC}"
echo -e "   Container : ${CONTAINER_NAME}"
echo -e "   OS        : ${WIN_VERSION}"
echo -e "   Game      : ${GAME_LABEL} (AppID ${STEAM_APP_ID})"
echo -e "   Route     : ${TARGET_IP}"
echo -e "   Web UI    : http://${TARGET_IP}:8006  (or Cloudflare URL if tunneled)"
echo -e "   RDP       : ${TARGET_IP}:3389"
echo -e "${GREEN}======================================================${NC}\n"
echo -e "${YELLOW}Note: First boot installs Windows + runs OEM install.bat (Steam + shortcut).${NC}"
echo -e "${YELLOW}This can take 10-30+ minutes depending on host and image size.${NC}"
