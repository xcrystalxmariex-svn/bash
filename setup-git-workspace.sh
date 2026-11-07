#!/data/data/com.termux/files/usr/bin/bash

set -e

echo "=== Setting Up 'gh:' Git URL Shorthand ==="

# 1. Apply to global git config so it works everywhere
git config --global url."https://github.com/".insteadOf "gh:"
echo "-> Added global rewrite: 'gh:' -> 'https://github.com/'"

# 2. Also ensure it's recorded directly in your /usr/repo scoped config if present
LOCAL_CONFIG="/data/data/com.termux/files/usr/repo/.gitconfig-local"
if [ -f "$LOCAL_CONFIG" ]; then
    git config --file "$LOCAL_CONFIG" url."https://github.com/".insteadOf "gh:"
    echo "-> Confirmed rewrite in $LOCAL_CONFIG"
fi

echo
echo "Verification:"
git config --get-regexp "url\..*\.insteadof"

echo
echo "Setup complete! You can now clone using:"
echo "  git clone gh:SeVin-DEV/<repo-name>"
echo "  git clone gh:xcrystalxmariex-svn/<repo-name>"
