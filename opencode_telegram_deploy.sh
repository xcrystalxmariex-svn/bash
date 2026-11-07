#!/usr/bin/env bash
# ==============================================================================
# OpenCode Agent & Telegram Bot Deployer
# Hardened + auto-restart + modern OpenCode install/update + PATH wrapper
# Termux-safe shebangs
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
    # Absolute Termux bash — /usr/bin/env does not exist on stock Termux
    BASH_SHEBANG="#!/data/data/com.termux/files/usr/bin/bash"
    echo "[+] Detected Environment: Termux on Android"
elif [ -f /etc/os-release ]; then
    ENV_TYPE="linux"
    BASH_SHEBANG="#!/usr/bin/env bash"
    echo "[+] Detected Environment: Standard Linux"
else
    ENV_TYPE="unknown"
    BASH_SHEBANG="#!/usr/bin/env bash"
    echo "[!] Unknown environment, defaulting to generic Linux layout"
fi

# ---------------------------------------------------------------------------
# 2. Package Manager & Base Dependencies
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
# 3. OpenCode — detect / update / install
# ---------------------------------------------------------------------------
echo "[*] Checking for OpenCode..."

install_opencode() {
    echo "[*] Installing / updating OpenCode..."
    local ok=0

    if npm install -g "@opencode/cli@latest" 2>/dev/null; then
        ok=1
    elif npm install -g "opencode-ai@latest" 2>/dev/null; then
        ok=1
    elif npm install -g "opencode@latest" 2>/dev/null; then
        ok=1
    elif curl -fsSL https://opencode.ai/install | bash; then
        ok=1
        if [ -d "$HOME/.opencode/bin" ]; then
            export PATH="$HOME/.opencode/bin:$PATH"
        fi
    fi

    if [ "$ok" -ne 1 ]; then
        echo "[-] Failed to install OpenCode. Install manually then re-run."
        echo "    Suggested:  npm i -g @opencode/cli@latest"
        echo "            or: curl -fsSL https://opencode.ai/install | bash"
        exit 1
    fi
}

if command -v opencode >/dev/null 2>&1; then
    CURRENT_VER=$(opencode --version 2>/dev/null || echo "unknown")
    echo "[+] OpenCode already present: $(command -v opencode)  (version: $CURRENT_VER)"
    echo "[*] Updating to latest..."
    install_opencode
    NEW_VER=$(opencode --version 2>/dev/null || echo "unknown")
    echo "[+] OpenCode after update: $NEW_VER"
else
    echo "[*] OpenCode not found — installing..."
    install_opencode
    if command -v opencode >/dev/null 2>&1; then
        echo "[+] OpenCode installed: $(command -v opencode)  ($(opencode --version 2>/dev/null || echo '?'))"
    else
        if [ -x "$HOME/.opencode/bin/opencode" ]; then
            export PATH="$HOME/.opencode/bin:$PATH"
            echo "[+] OpenCode found at $HOME/.opencode/bin/opencode"
        else
            echo "[-] opencode binary still not on PATH after install."
            exit 1
        fi
    fi
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

if [ ! -f "$WORKDIR/.gitignore" ]; then
    cat > "$WORKDIR/.gitignore" <<'GITIGNORE'
.env
venv/
*.log
*.pid
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

_last_prompt: Dict[int, str] = {}


async def query_opencode(prompt: str, user_id: int) -> str:
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
            "Ensure the server is running (auto-restart should recover shortly)."
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
        "• Clear Context – forget last prompt for this chat\n"
        "• Server Health – ping local OpenCode\n"
        "• Regenerate – re-run the last prompt",
        reply_markup=reply_markup,
    )


async def handle_text(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not update.message or not update.message.text:
        return

    user_text = update.message.text
    user_id = update.effective_user.id
    chat_id = update.effective_chat.id

    _last_prompt[chat_id] = user_text

    await context.bot.send_chat_action(chat_id=chat_id, action="typing")
    response = await query_opencode(user_text, user_id)

    keyboard = [[InlineKeyboardButton("Regenerate", callback_data="regen")]]
    reply_markup = InlineKeyboardMarkup(keyboard)

    if len(response) > 4000:
        for i in range(0, len(response), 4000):
            chunk = response[i : i + 4000]
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
            status = f"OpenCode Offline (port {OPENCODE_PORT}) — watchdog should restart it shortly."
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
# 7. Generate hardened start.sh WITH AUTO-RESTART WATCHDOG
#    (Termux-safe shebang)
# ---------------------------------------------------------------------------
cat > "$WORKDIR/start.sh" << EOF
${BASH_SHEBANG}
set -euo pipefail

DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
cd "\$DIR"

# Safe env loading
if [ -f .env ]; then
    set -a
    # shellcheck source=/dev/null
    source .env
    set +a
else
    echo "[-] Missing .env file. Re-run the deployer."
    exit 1
fi

PORT="\${OPENCODE_PORT:-4096}"
HOST="\${OPENCODE_HOST:-127.0.0.1}"
LOG="\$DIR/opencode_server.log"
PIDFILE="\$DIR/opencode.pid"
WATCHDOG_INTERVAL=15

# Termux wake lock
if command -v termux-wake-lock >/dev/null 2>&1; then
    termux-wake-lock || true
    echo "[+] Activated Termux wake lock."
fi

# Ensure ~/.opencode/bin is on PATH if the curl installer was used
if [ -d "\$HOME/.opencode/bin" ]; then
    export PATH="\$HOME/.opencode/bin:\$PATH"
fi

# shellcheck source=/dev/null
source venv/bin/activate

port_in_use() {
    if command -v ss >/dev/null 2>&1; then
        ss -tuln 2>/dev/null | grep -q ":\${PORT} "
    elif command -v lsof >/dev/null 2>&1; then
        lsof -i ":\${PORT}" >/dev/null 2>&1
    else
        (echo >/dev/tcp/127.0.0.1/"\${PORT}") >/dev/null 2>&1
    fi
}

start_opencode() {
    if [ -f "\$PIDFILE" ]; then
        oldpid=\$(cat "\$PIDFILE" 2>/dev/null || true)
        if [ -n "\$oldpid" ] && kill -0 "\$oldpid" 2>/dev/null; then
            kill "\$oldpid" 2>/dev/null || true
            sleep 1
        fi
        rm -f "\$PIDFILE"
    fi

    echo "[*] Starting OpenCode on \${HOST}:\${PORT}..."
    nohup opencode serve --port "\$PORT" >> "\$LOG" 2>&1 &
    echo \$! > "\$PIDFILE"
    echo "[+] OpenCode PID \$(cat "\$PIDFILE") (log: \$LOG)"
    sleep 2
}

if port_in_use; then
    echo "[+] Port \$PORT already in use — assuming OpenCode is running."
else
    start_opencode
    if ! port_in_use; then
        echo "[!] OpenCode did not bind to port \$PORT. Check \$LOG"
    fi
fi

# Background watchdog
(
    while true; do
        sleep "\$WATCHDOG_INTERVAL"
        if ! port_in_use; then
            echo "\$(date -Is) [watchdog] OpenCode not listening on :\$PORT — restarting" >> "\$LOG"
            start_opencode
        fi
    done
) &
WATCHDOG_PID=\$!
echo "[+] Watchdog running (PID \$WATCHDOG_PID, interval \${WATCHDOG_INTERVAL}s)"

trap 'kill \$WATCHDOG_PID 2>/dev/null || true' EXIT

echo "[*] Starting Telegram Bot bridge (foreground)..."
exec python3 bridge.py
EOF

chmod 755 "$WORKDIR/start.sh"

# ---------------------------------------------------------------------------
# 8. Install PATH wrappers (Termux-safe shebang)
# ---------------------------------------------------------------------------
WRAPPER_BODY="${BASH_SHEBANG}
# Launches the OpenCode + Telegram agent stack
exec \"${WORKDIR}/start.sh\" \"\$@\"
"

install_wrapper() {
    local dest="$1"
    local name="$2"
    printf '%s\n' "$WRAPPER_BODY" > "$dest/$name"
    chmod 755 "$dest/$name"
    echo "[+] Installed wrapper: $dest/$name"
}

if [ "$ENV_TYPE" = "termux" ] && [ -d "${PREFIX:-/data/data/com.termux/files/usr}/bin" ]; then
    install_wrapper "${PREFIX}/bin" "opencode-bot"
    install_wrapper "${PREFIX}/bin" "oc-agent"
elif [ -d "$HOME/bin" ]; then
    install_wrapper "$HOME/bin" "opencode-bot"
    install_wrapper "$HOME/bin" "oc-agent"
    case ":$PATH:" in
        *":$HOME/bin:"*) ;;
        *) echo "[!] $HOME/bin is not on PATH — add it or re-login" ;;
    esac
elif [ -w /usr/local/bin ] 2>/dev/null; then
    install_wrapper "/usr/local/bin" "opencode-bot"
    install_wrapper "/usr/local/bin" "oc-agent"
else
    mkdir -p "$HOME/bin"
    install_wrapper "$HOME/bin" "opencode-bot"
    install_wrapper "$HOME/bin" "oc-agent"
    echo "[!] Added wrappers to $HOME/bin — ensure it is on your PATH:"
    echo "    export PATH=\"\$HOME/bin:\$PATH\""
fi

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
echo "Launch the full agent + Telegram stack from anywhere:"
echo "  opencode-bot"
echo "  # or"
echo "  oc-agent"
echo ""
echo "  (or:  cd $WORKDIR && ./start.sh)"
echo ""
echo "OpenCode CLI itself remains available as:  opencode"
echo ""
echo "Auto-restart: watchdog checks the serve port every 15s and"
echo "restarts OpenCode if it dies. Log: $WORKDIR/opencode_server.log"
echo "=========================================="
