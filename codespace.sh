#!/data/data/com.termux/files/usr/bin/bash

CONFIG_DIR="$HOME/.config/termux-codespaces"
HISTORY_FILE="$CONFIG_DIR/history.log"
mkdir -p "$CONFIG_DIR"
touch "$HISTORY_FILE"

# 1. Dependency verification
for pkg in gh openssh; do
    if ! command -v "$pkg" >/dev/null 2>&1; then
        echo "[*] Installing missing dependency: $pkg..."
        pkg install -y "$pkg"
    fi
done

# 2. Credential verification
if ! gh auth status >/dev/null 2>&1; then
    echo "[!] No active GitHub session found."
    echo "[*] Authenticating with GitHub..."
    gh auth login -p https -w -s codespace
fi

# Function: Connect to codespace via SSH
connect_codespace() {
    local cs_name="$1"
    echo "[*] Connecting to $cs_name via SSH..."
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $cs_name" >> "$HISTORY_FILE"
    gh codespace ssh -c "$cs_name"
}

# Function: Create a new codespace
create_new_codespace() {
    echo ""
    echo "--- Select Repository ---"
    echo "1) Pick from recent repositories"
    echo "2) Enter repository manually (owner/repo)"
    read -rp "Choice [1-2]: " repo_mode

    local target_repo=""
    if [ "$repo_mode" = "1" ]; then
        echo "[*] Fetching your repositories..."
        mapfile -t repos < <(gh repo list --limit 25 --json nameWithOwner -q '.[].nameWithOwner' 2>/dev/null)
        if [ ${#repos[@]} -eq 0 ]; then
            echo "[!] No repositories returned. Falling back to manual entry."
            read -rp "Enter repo (e.g., owner/repo): " target_repo
        else
            echo "Select a repository:"
            select r in "${repos[@]}" "Cancel"; do
                if [ "$r" = "Cancel" ]; then
                    return
                elif [ -n "$r" ]; then
                    target_repo="$r"
                    break
                else
                    echo "Invalid option."
                fi
            done
        fi
    else
        read -rp "Enter repository (owner/repo): " target_repo
    fi

    if [ -z "$target_repo" ]; then
        echo "[!] Repository cannot be empty."
        return
    fi

    echo "[*] Provisioning codespace for $target_repo..."
    
    # gh codespace create streams spinner/status to stderr and prints only the codespace name to stdout
    cs_name=$(gh codespace create -R "$target_repo" --default-permissions | tr -d '\r' | awk 'NF{p=$0} END{print p}')

    if [ -n "$cs_name" ]; then
        echo "[✓] Codespace created: $cs_name"
        connect_codespace "$cs_name"
    else
        echo "[!] Failed to provision codespace. Check repository name and permissions."
    fi
}

# 3. Main Interface
while true; do
    echo ""
    echo "================================="
    echo "      Termux Codespace CLI       "
    echo "================================="
    
    mapfile -t live_cs < <(gh codespace list --json name,repository,state --template '{{range .}}{{.name}} | {{.repository}} | {{.state}}{{"\n"}}{{end}}' 2>/dev/null)

    echo "1) Create a new Codespace"
    if [ ${#live_cs[@]} -gt 0 ]; then
        echo "2) Re-enter an active Codespace (${#live_cs[@]} available)"
    else
        echo "2) Re-enter an active Codespace (none running)"
    fi
    echo "3) View local connection history"
    echo "4) Exit"
    read -rp "Select an option [1-4]: " menu_choice

    case "$menu_choice" in
        1)
            create_new_codespace
            ;;
        2)
            if [ ${#live_cs[@]} -eq 0 ]; then
                echo "[!] No active codespaces found."
                continue
            fi
            echo ""
            echo "--- Available Codespaces ---"
            select cs_entry in "${live_cs[@]}" "Back"; do
                if [ "$cs_entry" = "Back" ]; then
                    break
                elif [ -n "$cs_entry" ]; then
                    raw_name=$(echo "$cs_entry" | awk -F ' \\| ' '{print $1}')
                    connect_codespace "$raw_name"
                    break
                else
                    echo "Invalid selection."
                fi
            done
            ;;
        3)
            echo ""
            echo "--- Connection History ---"
            if [ -s "$HISTORY_FILE" ]; then
                tail -n 15 "$HISTORY_FILE"
            else
                echo "No history logged yet."
            fi
            ;;
        4)
            echo "Exiting."
            exit 0
            ;;
        *)
            echo "Invalid selection."
            ;;
    esac
done
