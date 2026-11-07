#!/data/data/com.termux/files/usr/bin/bash

STORAGE="$HOME/storage"

if [ ! -d "$STORAGE" ]; then
    echo "Error: ~/storage symlinks not found. Run 'termux-setup-storage' first."
    exit 1
fi

echo "=== Termux ~/storage Cleaner ==="
echo "Note: Targets shared Android storage (/storage/emulated/0)"
echo

# 1. Stale temporary archives (.zip, .tar.gz, .tgz, .bak) in Downloads
echo "[1/4] Stale Archive Dumps in Downloads"
downloads="$STORAGE/downloads"
if [ -d "$downloads" ]; then
    stray_zips=$(find "$downloads" -maxdepth 2 -type f \( -name "*.zip" -o -name "*.tar.gz" -o -name "*.tgz" -o -name "*.bak" \) 2>/dev/null)
    if [ -n "$stray_zips" ]; then
        echo "Found potentially leftover archives:"
        echo "$stray_zips" | while read -r f; do
            sz=$(du -h "$f" 2>/dev/null | cut -f1)
            echo "  - $f ($sz)"
        done
        read -p "      Review or delete any of these archives? (y/N): " choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            echo "$stray_zips" | while read -r f; do
                read -p "        Delete $(basename "$f")? (y/N): " del_choice
                if [[ "$del_choice" =~ ^[Yy]$ ]]; then
                    rm -f "$f"
                    echo "        Removed."
                fi
            done
        fi
    else
        echo "      No stray zip/tar archives found in root Downloads."
    fi
fi
echo

# 2. Large leftover APK builds or package files
echo "[2/4] Leftover APK & Package Builds"
apk_files=$(find "$downloads" "$STORAGE/shared" -maxdepth 3 -type f \( -name "*.apk" -o -name "*.aab" -o -name "*.deb" \) 2>/dev/null)
if [ -n "$apk_files" ]; then
    echo "Found installer/build files:"
    echo "$apk_files" | while read -r f; do
        sz=$(du -h "$f" 2>/dev/null | cut -f1)
        echo "  - $f ($sz)"
    done
    read -p "      Prompt to delete individual package/build files? (y/N): " choice
    if [[ "$choice" =~ ^[Yy]$ ]]; then
        echo "$apk_files" | while read -r f; do
            read -p "        Delete $(basename "$f")? (y/N): " del_choice
            if [[ "$del_choice" =~ ^[Yy]$ ]]; then
                rm -f "$f"
                echo "        Removed."
            fi
        done
    fi
else
    echo "      No loose APK/DEB packages found."
fi
echo

# 3. Hidden .trash or .thumbnails eating storage in shared space
echo "[3/4] Hidden Trash & Gallery Thumbnails"
for junk_dir in "$STORAGE/shared/.thumbnails" "$STORAGE/shared/Android/data/com.termux/files" "$STORAGE/downloads/.trash"; do
    if [ -d "$junk_dir" ]; then
        sz=$(du -sh "$junk_dir" 2>/dev/null | cut -f1)
        read -p "      Clear $junk_dir ($sz)? (y/N): " choice
        if [[ "$choice" =~ ^[Yy]$ ]]; then
            rm -rf "$junk_dir"/* 2>/dev/null || true
            echo "      Cleared."
        fi
    fi
done
echo

# 4. Top 15 largest files across Downloads and Shared
echo "[4/4] Top 15 Largest Files in Downloads & Shared"
echo "Scanning (this may take a few seconds)..."
find "$STORAGE/downloads" "$STORAGE/shared" -type f -not -path '*/.*' -exec du -h {} + 2>/dev/null | sort -rh | head -n 15
echo
echo "=== Done ==="
