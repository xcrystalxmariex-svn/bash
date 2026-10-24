#!/usr/bin/env bash
# ==============================================================================
# Abyssal Terminal - Universal Headless Android APK Builder (Ubuntu & Termux)
# ==============================================================================
set -euo pipefail

RESET="\033[0m"
CYAN="\033[36m"
PINK="\033[38;5;204m"
VIOLET="\033[38;5;141m"
GREEN="\033[32m"
RED="\033[31m"
YELLOW="\033[33m"
GRAY="\033[90m"

IS_TERMUX=false
if [ -d "/data/data/com.termux" ] || [ -n "${TERMUX_VERSION:-}" ]; then
    IS_TERMUX=true
fi

print_banner() {
    clear 2>/dev/null || true
    echo -e "${VIOLET}================================================================${RESET}"
    echo -e "${PINK}            ABYSSAL TERMINAL // APK BUILD PIPELINE            ${RESET}"
    echo -e "${VIOLET}================================================================${RESET}"
    if [ "$IS_TERMUX" = true ]; then
        echo -e "${CYAN} Target Environment:${RESET} Android Termux Node"
    else
        echo -e "${CYAN} Target Environment:${RESET} Headless Ubuntu Build Node"
    fi
    echo -e "${CYAN} Status:${RESET} Operational\n"
}

log()  { echo -e "${CYAN}[*]${RESET} $*"; }
ok()   { echo -e "${GREEN}[+]${RESET} $*"; }
warn() { echo -e "${YELLOW}[!]${RESET} $*"; }
err()  { echo -e "${RED}[!]${RESET} $*" >&2; }

collect_gradle_text() {
    local root="$1"
    local files=()
    for f in \
        "$root/build.gradle.kts" "$root/build.gradle" \
        "$root/settings.gradle.kts" "$root/settings.gradle" \
        "$root/app/build.gradle.kts" "$root/app/build.gradle" \
        "$root/gradle/libs.versions.toml" \
        "$root/gradle.properties"
    do
        [ -f "$f" ] && files+=("$f")
    done
    while IFS= read -r -d '' f; do
        files+=("$f")
    done < <(find "$root" -maxdepth 2 \( -name 'build.gradle.kts' -o -name 'build.gradle' \) -print0 2>/dev/null || true)
    if [ ${#files[@]} -eq 0 ]; then
        echo ""
        return
    fi
    cat "${files[@]}" 2>/dev/null || true
}

detect_sdk_api() {
    local text="$1"
    local api=""
    api=$(printf '%s\n' "$text" | grep -oE 'compileSdk[^0-9]{0,40}([0-9]{2,3})' | grep -oE '[0-9]{2,3}' | sort -n | tail -1 || true)
    if [ -z "$api" ]; then
        api=$(printf '%s\n' "$text" | grep -oE 'targetSdk[^0-9]{0,40}([0-9]{2,3})' | grep -oE '[0-9]{2,3}' | sort -n | tail -1 || true)
    fi
    echo "${api:-34}"
}

detect_min_sdk() {
    local text="$1"
    local api
    api=$(printf '%s\n' "$text" | grep -oE 'minSdk[^0-9]{0,40}([0-9]{2,3})' | grep -oE '[0-9]{2,3}' | sort -n | tail -1 || true)
    echo "${api:-24}"
}

detect_ndk_version() {
    local text="$1"
    local ver
    ver=$(printf '%s\n' "$text" | grep -oE 'ndkVersion\s*=\s*["'\''"]([0-9]+\.[0-9]+\.[0-9]+)["'\''"]' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
    if [ -z "$ver" ]; then
        ver=$(printf '%s\n' "$text" | grep -oE 'ndk;([0-9]+\.[0-9]+\.[0-9]+)' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
    fi
    echo "${ver:-}"
}

detect_flavors() {
    local text="$1"
    local flavors=()
    while IFS= read -r name; do
        [ -n "$name" ] && flavors+=("$name")
    done < <(printf '%s\n' "$text" | grep -oE 'create\(\s*["'\''"]([A-Za-z0-9_]+)["'\''"]\s*\)' | sed -E 's/.*["'\''"]([A-Za-z0-9_]+)["'\''"].*/\1/' | sort -u)
    if [ ${#flavors[@]} -eq 0 ]; then
        echo ""
    else
        printf '%s\n' "${flavors[@]}"
    fi
}

pick_build_tools() {
    local api="$1"
    case "$api" in
        36) echo "build-tools;36.0.0" ;;
        35) echo "build-tools;35.0.0" ;;
        34) echo "build-tools;34.0.0" ;;
        33) echo "build-tools;33.0.2" ;;
        *)  echo "build-tools;34.0.0" ;;
    esac
}

find_output_apk() {
    local root="$1"
    local flavor="$2"
    local btype="$3"
    local search_roots=("$root/app/build/outputs/apk" "$root/build/outputs/apk")
    local candidates=()
    local sr c score best_score=-1 scored_best="" low
    for sr in "${search_roots[@]}"; do
        [ -d "$sr" ] || continue
        while IFS= read -r -d '' f; do
            candidates+=("$f")
        done < <(find "$sr" -type f -name "*.apk" -print0 2>/dev/null || true)
    done
    if [ ${#candidates[@]} -eq 0 ]; then
        echo ""
        return
    fi
    for c in "${candidates[@]}"; do
        score=0
        low=$(echo "$c" | tr '[:upper:]' '[:lower:]')
        if [ -n "$flavor" ] && echo "$low" | grep -q "$(echo "$flavor" | tr '[:upper:]' '[:lower:]')"; then
            score=$((score + 3))
        fi
        if echo "$low" | grep -q "$(echo "$btype" | tr '[:upper:]' '[:lower:]')"; then
            score=$((score + 2))
        fi
        if echo "$low" | grep -qE 'androidtest|unsigned'; then
            score=$((score - 2))
        fi
        if [ "$score" -gt "$best_score" ]; then
            best_score=$score
            scored_best="$c"
        fi
    done
    echo "$scored_best"
}

install_dependencies() {
    local need_api="${1:-34}"
    local need_ndk="${2:-}"
    local build_tools_pkg
    build_tools_pkg=$(pick_build_tools "$need_api")
    print_banner
    if [ "$IS_TERMUX" = true ]; then
        log "Installing Termux dependencies (Java 17, Git, Unzip, Wget)..."
        pkg update -y
        pkg install -y openjdk-17 git unzip wget curl coreutils || true
        if [ -d "$PREFIX/lib/jvm/java-17-openjdk" ]; then
            export JAVA_HOME="$PREFIX/lib/jvm/java-17-openjdk"
        elif [ -d "$PREFIX/usr/lib/jvm/java-17" ]; then
            export JAVA_HOME="$PREFIX/usr/lib/jvm/java-17"
        fi
        SDK_BASE="${HOME}/storage/shared/Download/android-sdk"
        BIN_DEST="$PREFIX/bin/build_apk"
    else
        log "Checking Ubuntu system dependencies (Java 17, Git, Unzip)..."
        if command -v sudo >/dev/null 2>&1; then
            sudo apt-get update -y
            sudo apt-get install -y openjdk-17-jdk git unzip wget curl
        else
            apt-get update -y
            apt-get install -y openjdk-17-jdk git unzip wget curl
        fi
        if [ -d /usr/lib/jvm/java-17-openjdk-amd64 ]; then
            export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
        elif [ -d /usr/lib/jvm/java-17-openjdk ]; then
            export JAVA_HOME=/usr/lib/jvm/java-17-openjdk
        fi
        SDK_BASE="${HOME}/android-sdk"
        BIN_DEST="/usr/local/bin/build_apk"
    fi
    export PATH="${PATH}:${JAVA_HOME:-}/bin"
    log "Setting up Android SDK Command-Line Tools under $SDK_BASE ..."
    mkdir -p "$SDK_BASE/cmdline-tools"
    local TEMP_DIR
    TEMP_DIR=$(mktemp -d)
    (
        cd "$TEMP_DIR"
        local ZIP_URL="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
        wget -q "$ZIP_URL" -O cmdline-tools.zip
        unzip -q cmdline-tools.zip
        rm -rf "$SDK_BASE/cmdline-tools/latest"
        mkdir -p "$SDK_BASE/cmdline-tools/latest"
        if [ -d cmdline-tools ]; then
            cp -a cmdline-tools/. "$SDK_BASE/cmdline-tools/latest/"
        else
            cp -a bin lib source.properties NOTICE.txt "$SDK_BASE/cmdline-tools/latest/" 2>/dev/null || cp -a . "$SDK_BASE/cmdline-tools/latest/"
        fi
    )
    rm -rf "$TEMP_DIR"
    chmod -R +x "$SDK_BASE/cmdline-tools/latest/bin/" 2>/dev/null || true
    export ANDROID_HOME="$SDK_BASE"
    export ANDROID_SDK_ROOT="$SDK_BASE"
    export PATH="$PATH:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools"
    if [ ! -x "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" ]; then
        err "sdkmanager binary missing after install."
        exit 1
    fi
    log "Accepting SDK licenses..."
    yes 2>/dev/null | "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --licenses >/dev/null 2>&1 || true
    local packages=("platform-tools" "platforms;android-${need_api}" "$build_tools_pkg")
    if [ "$need_api" -gt 34 ] 2>/dev/null; then
        packages+=("platforms;android-34" "build-tools;34.0.0")
    fi
    if [ -n "$need_ndk" ]; then
        packages+=("ndk;${need_ndk}" "cmake;3.22.1")
    fi
    log "Installing SDK packages: ${packages[*]}"
    "${ANDROID_HOME}/cmdline-tools/latest/bin/sdkmanager" "${packages[@]}" || {
        warn "Some sdkmanager packages failed — retrying individually..."
        local p
        for p in "${packages[@]}"; do
            "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" "$p" || warn "Failed: $p"
        done
    }
    if [ "$IS_TERMUX" = true ]; then
        if ! grep -q "ANDROID_HOME" ~/.bashrc 2>/dev/null; then
            {
                echo "export ANDROID_HOME=$SDK_BASE"
                echo "export ANDROID_SDK_ROOT=$SDK_BASE"
                echo "export PATH=\$PATH:\$ANDROID_HOME/cmdline-tools/latest/bin:\$ANDROID_HOME/platform-tools"
            } >> ~/.bashrc
        fi
        cp "$(realpath "$0")" "$BIN_DEST"
        chmod +x "$BIN_DEST"
    else
        if [ -w /usr/local/bin ] || command -v sudo >/dev/null 2>&1; then
            if [ ! -e /usr/local/bin/build_apk ]; then
                log "Installing build_apk shortcut..."
                if command -v sudo >/dev/null 2>&1; then
                    sudo ln -sf "$(realpath "$0")" /usr/local/bin/build_apk
                    sudo chmod +x /usr/local/bin/build_apk
                else
                    ln -sf "$(realpath "$0")" /usr/local/bin/build_apk
                    chmod +x /usr/local/bin/build_apk
                fi
            fi
        fi
    fi
    ok "SDK init complete."
}

ensure_sdk_for_project() {
    local api="$1"
    local ndk="$2"
    local SDK_CHECK="$HOME/android-sdk"
    if [ "$IS_TERMUX" = true ]; then
        SDK_CHECK="$HOME/storage/shared/Download/android-sdk"
    fi
    export ANDROID_HOME="${ANDROID_HOME:-$SDK_CHECK}"
    export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$ANDROID_HOME}"
    if [ ! -x "${ANDROID_HOME}/cmdline-tools/latest/bin/sdkmanager" ]; then
        install_dependencies "$api" "$ndk"
        return
    fi
    if [ ! -d "${ANDROID_HOME}/platforms/android-${api}" ]; then
        log "Missing platforms;android-${api} — installing..."
        yes 2>/dev/null | "${ANDROID_HOME}/cmdline-tools/latest/bin/sdkmanager" --licenses >/dev/null 2>&1 || true
        "${ANDROID_HOME}/cmdline-tools/latest/bin/sdkmanager" "platforms;android-${api}" "$(pick_build_tools "$api")" || true
    fi
    if [ -n "$ndk" ] && [ ! -d "${ANDROID_HOME}/ndk/${ndk}" ]; then
        log "Missing NDK ${ndk} — installing..."
        "${ANDROID_HOME}/cmdline-tools/latest/bin/sdkmanager" "ndk;${ndk}" "cmake;3.22.1" || true
    fi
}

print_banner

echo -e "${PINK}[?] Select input source type:${RESET}"
echo -e "  ${VIOLET}1)${RESET} Git Repository URL"
echo -e "  ${VIOLET}2)${RESET} Local directory path"
echo -e "  ${VIOLET}3)${RESET} Local Zip archive (.zip)"
read -rp "Selection [1/3]: " input_type

WORK_DIR=""
if [ "$input_type" = "1" ]; then
    read -rp "Enter Git repository URL: " repo_url
    read -rp "Perform shallow clone (--depth 1)? [y/N]: " shallow_choice
    read -rp "Clone with submodules (recursive)? [y/N]: " recursive_choice
    
    WORK_DIR="$HOME/agora_workspace"
    if [ -d "$WORK_DIR" ]; then
        log "Existing workspace found at $WORK_DIR. Pulling latest updates..."
        cd "$WORK_DIR"
        git pull || true
    else
        log "Cloning into permanent workspace: $WORK_DIR ..."
        CLONE_ARGS=()
        if [[ "$shallow_choice" =~ ^[Yy]$ ]]; then
            CLONE_ARGS+=("--depth" "1")
        fi
        if [[ "$recursive_choice" =~ ^[Yy]$ ]]; then
            CLONE_ARGS+=("--recursive")
        fi

        git clone "${CLONE_ARGS[@]}" "$repo_url" "$WORK_DIR" || {
            git clone "$repo_url" "$WORK_DIR"
        }
    fi
    cd "$WORK_DIR"
elif [ "$input_type" = "2" ]; then
    read -rp "Enter absolute path to project root: " local_path
    if [ ! -d "$local_path" ]; then
        err "Directory '$local_path' does not exist."
        exit 1
    fi
    WORK_DIR="$(cd "$local_path" && pwd)"
elif [ "$input_type" = "3" ]; then
    read -rp "Enter absolute path to the .zip archive: " zip_path
    if [ ! -f "$zip_path" ]; then
        err "Zip file '$zip_path' does not exist."
        exit 1
    fi
    WORK_DIR="$HOME/agora_workspace"
    mkdir -p "$WORK_DIR"
    log "Extracting ZIP archive into $WORK_DIR..."
    unzip -q -o "$zip_path" -d "$WORK_DIR"
    EXTRACTED_COUNT=$(ls -A "$WORK_DIR" | wc -l)
    if [ "$EXTRACTED_COUNT" -eq 1 ]; then
        SINGLE_SUBDIR=$(ls -1 "$WORK_DIR" | head -n 1)
        if [ -d "$WORK_DIR/$SINGLE_SUBDIR" ] && { [ -f "$WORK_DIR/$SINGLE_SUBDIR/settings.gradle" ] || [ -f "$WORK_DIR/$SINGLE_SUBDIR/settings.gradle.kts" ]; }; then
            WORK_DIR="$WORK_DIR/$SINGLE_SUBDIR"
        fi
    fi
    cd "$WORK_DIR"
else
    err "Invalid selection."
    exit 1
fi

log "Verifying Git submodules..."
cd "$WORK_DIR"
if [ -d ".git" ] && [ -f ".gitmodules" ]; then
    git submodule update --init --recursive
    if [ -d "thirdparty/llama.cpp" ]; then
        ok "Submodule 'thirdparty/llama.cpp' verified successfully."
    else
        warn "Submodule 'thirdparty/llama.cpp' is missing or empty. Forcing checkout..."
        git submodule foreach --recursive git submodule update --init || true
    fi
else
    log "No git submodules defined in this repository."
fi

if [ ! -f "$WORK_DIR/gradlew" ] && [ ! -f "$WORK_DIR/gradlew.bat" ]; then
    err "No gradlew in project root. Is this an Android Gradle project?"
    exit 1
fi
chmod +x "$WORK_DIR/gradlew" 2>/dev/null || true

log "Inspecting project Gradle files..."
GRADLE_TEXT=$(collect_gradle_text "$WORK_DIR")
SDK_API=$(detect_sdk_api "$GRADLE_TEXT")
MIN_SDK=$(detect_min_sdk "$GRADLE_TEXT")
NDK_VER=$(detect_ndk_version "$GRADLE_TEXT")
mapfile -t FLAVORS < <(detect_flavors "$GRADLE_TEXT")

echo -e "${CYAN}Detected compile/target SDK:${RESET} ${SDK_API}"
echo -e "${CYAN}Detected minSdk:${RESET}           ${MIN_SDK}"
if [ -n "$NDK_VER" ]; then
    echo -e "${CYAN}Detected ndkVersion:${RESET}       ${NDK_VER}"
else
    echo -e "${CYAN}Detected ndkVersion:${RESET}       (none declared)"
fi
if [ ${#FLAVORS[@]} -eq 0 ] || [ -z "${FLAVORS[0]:-}" ]; then
    echo -e "${CYAN}Detected product flavors:${RESET}  (none — plain debug/release)"
    FLAVORS=()
else
    echo -e "${CYAN}Detected product flavors:${RESET}  ${FLAVORS[*]}"
fi
echo

ensure_sdk_for_project "$SDK_API" "$NDK_VER"

if [ "$IS_TERMUX" = true ]; then
    export ANDROID_HOME="${HOME}/storage/shared/Download/android-sdk"
else
    export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk-amd64}"
    export ANDROID_HOME="${ANDROID_HOME:-$HOME/android-sdk}"
fi
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PATH="${PATH}:${JAVA_HOME:-}/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools"
echo "sdk.dir=${ANDROID_HOME}" > "$WORK_DIR/local.properties"

echo -e "${PINK}[?] Select build type:${RESET}"
echo -e "  ${VIOLET}1)${RESET} debug"
echo -e "  ${VIOLET}2)${RESET} release"
read -rp "Selection [1/2]: " variant_choice
BUILD_TYPE="debug"
if [ "$variant_choice" = "2" ]; then
    BUILD_TYPE="release"
fi

FLAVOR=""
if [ ${#FLAVORS[@]} -gt 0 ] && [ -n "${FLAVORS[0]:-}" ]; then
    echo -e "\n${PINK}[?] Select product flavor:${RESET}"
    echo -e "  ${VIOLET}0)${RESET} none (assembleDebug/Release only)"
    i=1
    for f in "${FLAVORS[@]}"; do
        echo -e "  ${VIOLET}${i})${RESET} $f"
        i=$((i + 1))
    done
    read -rp "Selection [0-${#FLAVORS[@]}]: " flavor_choice
    if [ "$flavor_choice" != "0" ] && [ -n "$flavor_choice" ]; then
        idx=$((flavor_choice - 1))
        if [ "$idx" -ge 0 ] && [ "$idx" -lt ${#FLAVORS[@]} ]; then
            FLAVOR="${FLAVORS[$idx]}"
        fi
    fi
fi

if [ -n "$FLAVOR" ]; then
    BT_CAP="$(echo "$BUILD_TYPE" | sed 's/^./\U&/')"
    FLAVOR_CAP="$(echo "$FLAVOR" | sed 's/^./\U&/')"
    BUILD_TASK="assemble${FLAVOR_CAP}${BT_CAP}"
else
    BT_CAP="$(echo "$BUILD_TYPE" | sed 's/^./\U&/')"
    BUILD_TASK="assemble${BT_CAP}"
fi

echo -e "\n${CYAN}Gradle task:${RESET}  ./gradlew ${BUILD_TASK}"
read -rp "Enter destination path for the finished APK: " dest_path

log "Running Gradle ($BUILD_TASK)..."
cd "$WORK_DIR"
BUILD_LOG=$(mktemp)
echo -e "${CYAN}Live Gradle output below (also saved to:${RESET} ${GRAY}$BUILD_LOG${RESET}${CYAN})${RESET}"
echo -e "${VIOLET}----------------------------------------------------------------${RESET}"

set +e
# Stream to terminal and log so long native/dependency phases never look frozen.
./gradlew "$BUILD_TASK" --stacktrace --no-daemon --console=plain 2>&1 | tee "$BUILD_LOG"
GRADLE_RC=${PIPESTATUS[0]}
set -e

echo -e "${VIOLET}----------------------------------------------------------------${RESET}"

if [ "$GRADLE_RC" -eq 0 ]; then
    BUILT_APK=$(find_output_apk "$WORK_DIR" "$FLAVOR" "$BUILD_TYPE")
    if [ -n "$BUILT_APK" ] && [ -f "$BUILT_APK" ]; then
        mkdir -p "$(dirname "$dest_path")"
        cp "$BUILT_APK" "$dest_path"
        ok "APK compiled successfully."
        echo -e "${CYAN}Source APK:${RESET} $BUILT_APK"
        echo -e "${CYAN}Saved to:${RESET}   $dest_path"
    else
        err "Gradle succeeded but no APK matched flavor='${FLAVOR:-none}' type='${BUILD_TYPE}'."
        exit 1
    fi
else
    err "Build failed. Tail of error log below:"
    echo -e "${VIOLET}----------------------------------------------------------------${RESET}"
    tail -n 80 "$BUILD_LOG"
    echo -e "${VIOLET}----------------------------------------------------------------${RESET}"
    echo -e "${GRAY}Full log saved at: $BUILD_LOG${RESET}"
    exit 1
fi
