#!/usr/bin/env bash
# ==============================================================================
# OpenCode Agent & Telegram Bot Deployer (Hardened)
# ==============================================================================
set -euo pipefail

echo "=========================================="
echo "  OpenCode Agent & Telegram Bot Deployer  "
echo "=========================================="

# ---------------------------------------------------------------------------
# 1. Environment Detection
# ---------------------------------------------------------------------------
if [ -n "${TERMUX_VERSION:-}" ] || [ -d "/data/data/com.termux" ]; then
    ENV_TYPE="termux"
    PREFIX_PATH="${PREFIX:-/data/data/com.termux/files/usr}"
    echo "[+] Detected Environment: Termux on Android"
elif [ -f /etc/os-release ]; then
    ENV_TYPE="linux"
    PREFIX_PATH="/usr"
    echo "[+] Detected Environment: Standard Linux"
else
    ENV_TYPE="unknown"
    PREFIX_PATH="/usr"
    echo "[!] Unknown environment, defaulting to generic Linux layout"
fi

# ---------------------------------------------------------------------------
# 2. Package Manager & Dependency Setup
# ---------------------------------------------------------------------------
echo "[*] Installing required base dependencies (Node.js, Python, Git, Curl, jq)..."

SUDO_CMD=""
if [ "$ENV_TYPE" != "termux" ] && [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
        SUDO_CMD="sudo"
    else
        echo "[-] Error: Root or sudo access required on Linux to install system packages."
        exit 1
    fi
fi

if [ "$ENV_TYPE" = "termux" ]; then
    pkg update -y
    pkg install -y nodejs-lts python git curl jq python-pip build-essential
else
    if command -v apt-get >/dev/null 2>&1; then
        $SUDO_CMD apt-get update -y
        $SUDO_CMD apt-get install -y nodejs npm python3 python3-pip python3-venv git curl jq
    elif command -v dnf >/dev/null 2>&1; then
        $SUDO_CMD dnf install -y nodejs npm python3 python3-pip git curl jq
    elif command -v pacman >/dev/null 2>&1; then
        $SUDO_CMD pacman -Sy --noconfirm nodejs npm python python-pip git curl jq
    else
        echo "[!] Unrecognized package manager. Ensure Node.js, npm, Python3, and pip are installed manually."
    fi
fi

# ---------------------------------------------------------------------------
# 3. OpenCode Installation
# ---------------------------------------------------------------------------
echo "[*] Checking for OpenCode installation..."
if ! command -v opencode >/dev/null 2>&1; then
    echo "[*] Installing opencode via npm (trying common package names)..."
    if [ "$ENV_TYPE" = "termux" ]; then
        npm install -g opencode-ai 2>/dev/null || npm install -g opencode || {
            echo "[-] Failed to install opencode. Install it manually and re-run."
            exit 1
        }
    else
        $SUDO_CMD npm install -g opencode-ai 2>/dev/null || $SUDO_CMD npm install -g opencode || {
            echo "[-] Failed to install opencode. Install it manually and re-run."
            exit 1
        }
    fi
else
    echo "[+] OpenCode is already installed: $(command -v opencode)"
fi

# ---------------------------------------------------------------------------
# 4. Project Workspace & Python Venv
# ---------------------------------------------------------------------------
WORKDIR="${HOME}/opencode-telegram-agent"
mkdir -p "$WORKDIR"
cd "$WORKDIR"

echo "[*] Configuring Python virtual environment in $WORKDIR..."
if [ ! -d "venv" ]; then
    python3 -m venv venv 2>/dev/null || python -m venv venv
fi

# shellcheck source=/dev/null
source venv/bin/activate

pip install --upgrade pip
pip install "python-telegram-bot>=20.0" "requests" "aiohttp"

# ---------------------------------------------------------------------------
# 5. Interactive Configuration (safe .env handling)
# ---------------------------------------------------------------------------
CONFIG_FILE="$WORKDIR/.env"

if [ ! -f "$CONFIG_FILE" ]; then
    echo ""
    echo "--- Configuration ---"
    echo "WARNING: The Telegram bot token will be stored in plaintext in $CONFIG_FILE"
    echo "         Keep this file private. It will be set to mode 600."
    read -r -p "Enter your Telegram Bot Token (from @BotFather): " TG_TOKEN
    if [ -z "$TG_TOKEN" ]; then
        echo "[-] Telegram Bot Token is required."
        exit 1
    fi
    read -r -p "Enter your OpenCode Server Port [default: 4096]: " OC_PORT
    OC_PORT="${OC_PORT:-4096}"

    cat > "$CONFIG_FILE" <<EOF
TELEGRAM_BOT_TOKEN=${TG_TOKEN}
OPENCODE_PORT=${OC_PORT}
OPENCODE_HOST=127.0.0.1
EOF
    chmod 600 "$CONFIG_FILE"
    echo "[+] Config saved to $CONFIG_FILE (mode 600)"
else
    echo "[+] Existing config found at $CONFIG_FILE"
    chmod 600 "$CONFIG_FILE" 2>/dev/null || true
fi

# Create a minimal .gitignore so the token is less likely to be committed
if [ ! -f "$WORKDIR/.gitignore" ]; then
    cat > "$WORKDIR/.gitignore" <<'GITIGNORE'
.env
venv/
*.log
__pycache__/
*.pyc
GITIGNORE
fi

# ---------------------------------------------------------------------------
# 6. Generate the hardened Telegram Bridge (bridge.py)
# ---------------------------------------------------------------------------
cat > "$WORKDIR/bridge.py" << 'EOF'
#!/usr/bin/env python3
"""OpenCode ↔ Telegram bridge (hardened)."""

from __future__ import annotations

import os
import sys
import logging
import asyncio
from typing import Dict

import aiohttp
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import (
    ApplicationBuilder,
    CommandHandler,
    MessageHandler,
    CallbackQueryHandler,
    ContextTypes,
    filters,
)

# Load configuration from environment (exported by start.sh)
TELEGRAM_BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN")
OPENCODE_HOST = os.getenv("OPENCODE_HOST", "127.0.0.1")
OPENCODE_PORT = os.getenv("OPENCODE_PORT", "4096")
OPENCODE_URL = f"http://{OPENCODE_HOST}:{OPENCODE_PORT}/v1/chat/completions"
HEALTH_URL = f"http://{OPENCODE_HOST}:{OPENCODE_PORT}/health"

logging.basicConfig(
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    level=logging.INFO,
)
logger = logging.getLogger("opencode-bridge")

# Simple in-memory last-prompt store for regenerate (per chat)
_last_prompt: Dict[int, str] = {}


async def query_opencode(prompt: str, user_id: int) -> str:
    """Send prompt to local OpenCode server (OpenAI-compatible shape)."""
    payload = {
        "model": "opencode",
        "messages": [{"role": "user", "content": prompt}],
        "user": str(user_id),
    }
    try:
        async with aiohttp.ClientSession() as session:
            async with session.post(OPENCODE_URL, json=payload, timeout=90) as resp:
                if resp.status == 200:
                    data = await resp.json()
                    choices = data.get("choices") or []
                    if choices:
                        return (
                            choices[0]
                            .get("message", {})
                            .get("content", "No content returned.")
                        )
                    return "OpenCode returned empty choices."
                text = await resp.text()
                return f"OpenCode Server Error {resp.status}: {text[:500]}"
    except aiohttp.ClientConnectorError:
        return (
            f"Could not connect to OpenCode at {OPENCODE_HOST}:{OPENCODE_PORT}. "
            "Ensure 'opencode serve' is running."
        )
    except asyncio.TimeoutError:
        return "Agent execution timed out (90s)."
    except Exception as e:
        logger.exception("query_opencode failed")
        return f"Error communicating with agent: {e}"


async def start_command(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    keyboard = [
        [
            InlineKeyboardButton("Clear Context", callback_data="clear_session"),
            InlineKeyboardButton("Server Health", callback_data="health_check"),
        ]
    ]
    reply_markup = InlineKeyboardMarkup(keyboard)
    await update.message.reply_text(
        "OpenCode Agent Bridge Active.\n"
        "Send any code instruction, command, or task.\n\n"
        "Buttons:\n"
        "• Clear Context – forget last prompt for this chat\n"
        "• Server Health – ping local OpenCode",
        reply_markup=reply_markup,
    )


async def handle_text(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not update.message or not update.message.text:
        return

    user_text = update.message.text
    user_id = update.effective_user.id
    chat_id = update.effective_chat.id

    # Remember for regenerate
    _last_prompt[chat_id] = user_text

    await context.bot.send_chat_action(chat_id=chat_id, action="typing")

    response = await query_opencode(user_text, user_id)

    keyboard = [[InlineKeyboardButton("Regenerate", callback_data="regen")]]
    reply_markup = InlineKeyboardMarkup(keyboard)

    # Telegram 4096 limit – leave margin
    if len(response) > 4000:
        for i in range(0, len(response), 4000):
            chunk = response[i : i + 4000]
            # Only attach button to the last chunk
            if i + 4000 >= len(response):
                await update.message.reply_text(chunk, reply_markup=reply_markup)
            else:
                await update.message.reply_text(chunk)
    else:
        await update.message.reply_text(response, reply_markup=reply_markup)


async def handle_callbacks(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()

    chat_id = query.message.chat_id if query.message else 0

    if query.data == "clear_session":
        _last_prompt.pop(chat_id, None)
        await query.edit_message_text("Session context cleared for this chat.")
    elif query.data == "health_check":
        try:
            async with aiohttp.ClientSession() as session:
                async with session.get(HEALTH_URL, timeout=5) as r:
                    status = (
                        f"OpenCode Status: {r.status} OK"
                        if r.status == 200
                        else f"OpenCode Alert: {r.status}"
                    )
        except Exception:
            status = f"OpenCode Offline (connection refused on port {OPENCODE_PORT})"
        await query.edit_message_text(status)
    elif query.data == "regen":
        last = _last_prompt.get(chat_id)
        if not last:
            await query.message.reply_text("No previous prompt stored for this chat.")
            return
        await query.message.reply_text("Re-running previous prompt…")
        await context.bot.send_chat_action(chat_id=chat_id, action="typing")
        response = await query_opencode(last, query.from_user.id)
        if len(response) > 4000:
            for i in range(0, len(response), 4000):
                await query.message.reply_text(response[i : i + 4000])
        else:
            await query.message.reply_text(response)


def main() -> None:
    if not TELEGRAM_BOT_TOKEN:
        print("ERROR: TELEGRAM_BOT_TOKEN is not set.", file=sys.stderr)
        sys.exit(1)

    app = ApplicationBuilder().token(TELEGRAM_BOT_TOKEN).build()
    app.add_handler(CommandHandler("start", start_command))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_text))
    app.add_handler(CallbackQueryHandler(handle_callbacks))

    print("[+] Telegram polling engine online.")
    app.run_polling(drop_pending_updates=True)


if __name__ == "__main__":
    main()
EOF

chmod 755 "$WORKDIR/bridge.py"

# ---------------------------------------------------------------------------
# 7. Generate hardened start.sh
# ---------------------------------------------------------------------------
cat > "$WORKDIR/start.sh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
cd "$DIR"

# Safe env loading (no word-splitting / injection from values)
if [ -f .env ]; then
    set -a
    # shellcheck source=/dev/null
    source .env
    set +a
else
    echo "[-] Missing .env file. Re-run the deployer."
    exit 1
fi

PORT="${OPENCODE_PORT:-4096}"
HOST="${OPENCODE_HOST:-127.0.0.1}"

# Keep Termux awake if available
if command -v termux-wake-lock >/dev/null 2>&1; then
    termux-wake-lock || true
    echo "[+] Activated Termux wake lock."
fi

# Activate venv
# shellcheck source=/dev/null
source venv/bin/activate

# Check whether something is already listening on the port
port_in_use() {
    if command -v ss >/dev/null 2>&1; then
        ss -tuln 2>/dev/null | grep -q ":${PORT} "
    elif command -v lsof >/dev/null 2>&1; then
        lsof -i ":${PORT}" >/dev/null 2>&1
    else
        # Fallback: try a quick connect
        (echo >/dev/tcp/127.0.0.1/"${PORT}") >/dev/null 2>&1
    fi
}

if ! port_in_use; then
    echo "[*] Launching OpenCode server on ${HOST}:${PORT}..."
    nohup opencode serve --port "$PORT" > "$DIR/opencode_server.log" 2>&1 &
    OC_PID=$!
    echo "[+] OpenCode started with PID $OC_PID (log: opencode_server.log)"
    # Give it a moment to bind
    sleep 3
    if ! port_in_use; then
        echo "[!] Warning: port $PORT still not listening. Check opencode_server.log"
    fi
else
    echo "[+] Something is already listening on port $PORT — assuming OpenCode is up."
fi

echo "[*] Starting Telegram Bot bridge..."
exec python3 bridge.py
EOF

chmod 755 "$WORKDIR/start.sh"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "=========================================="
echo "           Deployment Complete            "
echo "=========================================="
echo "Project directory : $WORKDIR"
echo "Config (mode 600) : $WORKDIR/.env"
echo ""
echo "To start the agent + Telegram bot:"
echo "  cd $WORKDIR && ./start.sh"
echo ""
echo "Notes:"
echo "  • Bot token is stored in plaintext .env — keep the directory private."
echo "  • OpenCode must speak an OpenAI-compatible /v1/chat/completions."
echo "  • Regenerate re-sends the last prompt stored for that chat."
echo "  • No automatic restart of OpenCode if it crashes; check the log."
echo "=========================================="
