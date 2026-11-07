#!/data/data/com.termux/files/usr/bin/bash

set -e

echo "=== Scoped Git Workspace Setup ==="
echo

# 1. Target Directory Selection
default_dir="$HOME/storage/shared/Termux/git_repos"
echo "Select where you want your parent Git workspace folder."
echo "Default: $default_dir"
read -p "Enter target path [Press Enter for default]: " TARGET_DIR
TARGET_DIR="${TARGET_DIR:-$default_dir}"

# Expand tilde if present
TARGET_DIR="${TARGET_DIR/#\~/$HOME}"

# Ensure trailing slash is stripped for folder operations
TARGET_DIR="${TARGET_DIR%/}"

echo "Target set to: $TARGET_DIR"
mkdir -p "$TARGET_DIR"
echo

# 2. Git Author Details
default_name="SeVin-DEV"
read -p "Git Commit Author Name [$default_name]: " GIT_USER
GIT_USER="${GIT_USER:-$default_name}"

default_email="xcrystalxmariex@gmail.com"
read -p "Git Commit Email [$default_email]: " GIT_EMAIL
GIT_EMAIL="${GIT_EMAIL:-$default_email}"
echo

# 3. GitHub Credentials
default_gh_user="xcrystalxmariex-svn"
read -p "GitHub Username [$default_gh_user]: " GH_USERNAME
GH_USERNAME="${GH_USERNAME:-$default_gh_user}"

echo "Enter your GitHub Personal Access Token (PAT):"
read -s -p "Token: " GH_TOKEN
echo
echo

if [ -z "$GH_TOKEN" ]; then
    echo "Warning: No token provided. You will be prompted on your first push/pull."
fi

# 4. Write Credential Store File (kept safe in Termux private home)
CRED_FILE="$HOME/.git-credentials-local"
touch "$CRED_FILE"
chmod 600 "$CRED_FILE"

if [ -n "$GH_TOKEN" ]; then
    # Remove any existing entry for github.com to avoid duplicates
    if [ -f "$CRED_FILE" ]; then
        sed -i '/github\.com/d' "$CRED_FILE" 2>/dev/null || true
    fi
    echo "https://${GH_USERNAME}:${GH_TOKEN}@github.com" >> "$CRED_FILE"
    echo "-> Saved token to $CRED_FILE (permissions set to 600)"
fi

# 5. Create Scoped .gitconfig inside the Workspace
CONFIG_LOCAL="$TARGET_DIR/.gitconfig-local"
cat << LOCAL_CONF > "$CONFIG_LOCAL"
[user]
    name = $GIT_USER
    email = $GIT_EMAIL

[credential]
    helper = store --file=$CRED_FILE

[credential "https://github.com"]
    username = $GH_USERNAME
LOCAL_CONF

echo "-> Created scoped config at $CONFIG_LOCAL"

# 6. Register Global conditional include & safe directories
# Trailing slash is mandatory for Git directory path matching
git config --global includeIf."gitdir:$TARGET_DIR/".path "$CONFIG_LOCAL"
echo "-> Registered includeIf for $TARGET_DIR/ in ~/.gitconfig"

# Safe directory handles Android FAT/fuse permission issues in /storage
git config --global --add safe.directory "$TARGET_DIR"
git config --global --add safe.directory "$TARGET_DIR/*"
echo "-> Configured safe.directory exceptions"

echo
echo "=== Setup Complete! ==="
echo "Workspace ready at: $TARGET_DIR"
echo
echo "Quick Test:"
echo "  cd $TARGET_DIR"
echo "  git config user.name"
echo "  git config credential.helper"
echo
