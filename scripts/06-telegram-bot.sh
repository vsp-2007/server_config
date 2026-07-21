#!/bin/bash
# Telegram Bot Module - Pi Server Setup v2
# Dual bot architecture (Admin + User) with security hardening

set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*"; }

# Config
TELEGRAM_ADMIN_TOKEN="${TELEGRAM_ADMIN_TOKEN:-}"
TELEGRAM_ADMIN_CHAT_ID="${TELEGRAM_ADMIN_CHAT_ID:-}"
TELEGRAM_USER_TOKEN="${TELEGRAM_USER_TOKEN:-}"
TELEGRAM_USER_CHAT_ID="${TELEGRAM_USER_CHAT_ID:-}"
PI_USER="${PI_USER:-piadmin}"

APP_DIR="/opt/pi-server-bot"
VENV_DIR="${APP_DIR}/venv"
SERVICE_USER="pi-bot"
BOT_SCRIPT="${APP_DIR}/dual_bot.py"

main() {
    log_info "Starting Telegram Bot setup..."
    
    # Validate required config
    if [[ -z "${TELEGRAM_ADMIN_TOKEN}" && -z "${TELEGRAM_USER_TOKEN}" ]]; then
        log_warn "No Telegram tokens configured. Skipping bot installation."
        log_info "Configure TELEGRAM_ADMIN_TOKEN and/or TELEGRAM_USER_TOKEN in settings.conf"
        return 0
    fi
    
    create_bot_user
    setup_python_environment
    deploy_bot_script
    install_systemd_service
    configure_logrotate
    
    log_success "Telegram Bot setup completed!"
}

create_bot_user() {
    log_info "Creating dedicated bot service user..."
    
    if ! id "${SERVICE_USER}" &>/dev/null; then
        useradd -r -s /bin/false -d "${APP_DIR}" -c "Pi Server Telegram Bot" "${SERVICE_USER}"
        log_info "Created user: ${SERVICE_USER}"
    else
        log_info "User ${SERVICE_USER} already exists"
    fi
    
    # Create app directory
    mkdir -p "${APP_DIR}"
    chown "${SERVICE_USER}:${SERVICE_USER}" "${APP_DIR}"
    chmod 750 "${APP_DIR}"
}

setup_python_environment() {
    log_info "Setting up Python virtual environment..."
    
    apt-get install -y -qq python3-venv python3-full
    
    if [[ ! -d "${VENV_DIR}" ]]; then
        sudo -u "${SERVICE_USER}" python3 -m venv "${VENV_DIR}"
    fi
    
    # Upgrade pip and install dependencies
    sudo -u "${SERVICE_USER}" "${VENV_DIR}/bin/pip" install --upgrade pip wheel setuptools
    sudo -u "${SERVICE_USER}" "${VENV_DIR}/bin/pip" install \
        "python-telegram-bot>=21.0" \
        "psutil>=5.9.0" \
        "aiohttp>=3.9.0" \
        "pydantic>=2.0" \
        "cryptography>=42.0"
    
    log_success "Python environment ready"
}

deploy_bot_script() {
    log_info "Deploying dual bot script..."
    
    cat > "${BOT_SCRIPT}" <<'PYTHON_SCRIPT'
#!/usr/bin/env python3
"""
Pi Server Dual Telegram Bot
- Admin Bot: Private control, system management, alerts
- User Bot: Public status reporting, group notifications

Security features:
- Runs as non-root user (pi-bot)
- Input validation and sanitization
- Rate limiting on commands
- Secure credential handling
- Audit logging
"""

import os
import asyncio
import json
import logging
import subprocess
import socket
import time
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Set
from dataclasses import dataclass, field

from telegram import Update, Bot
from telegram.ext import (
    Application,
    CommandHandler,
    ContextTypes,
    filters,
    MessageHandler,
)
from telegram.constants import ParseMode
import psutil

# =============================================================================
# CONFIGURATION
# =============================================================================

@dataclass
class BotConfig:
    admin_token: str = ""
    admin_chat_id: str = ""
    user_token: str = ""
    user_chat_id: str = ""
    
    # Rate limiting
    max_commands_per_minute: int = 20
    max_commands_per_hour: int = 100
    
    # Security
    allowed_admin_commands: Set[str] = field(default_factory=lambda: {
        "reboot", "restart", "pihole", "status", "pihole_stats",
        "approve", "deny", "announce", "pdr", "shutdown"
    })
    allowed_user_commands: Set[str] = field(default_factory=lambda: {
        "start", "status", "pihole_stats", "pdr", "help"
    })
    
    # Paths
    broadcast_list_file: Path = Path("/opt/pi-server-bot/broadcast_list.json")
    pending_requests_file: Path = Path("/opt/pi-server-bot/pending_requests.json")
    audit_log_file: Path = Path("/var/log/pi-server-bot/audit.log")

# Load config from environment
CONFIG = BotConfig(
    admin_token=os.getenv("TELEGRAM_ADMIN_TOKEN", ""),
    admin_chat_id=os.getenv("TELEGRAM_ADMIN_CHAT_ID", ""),
    user_token=os.getenv("TELEGRAM_USER_TOKEN", ""),
    user_chat_id=os.getenv("TELEGRAM_USER_CHAT_ID", ""),
)

# =============================================================================
# LOGGING SETUP
# =============================================================================

# Ensure log directory exists
CONFIG.audit_log_file.parent.mkdir(parents=True, exist_ok=True)

# Configure logging
logging.basicConfig(
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    level=logging.INFO,
    handlers=[
        logging.FileHandler("/var/log/pi-server-bot/bot.log"),
        logging.StreamHandler(),
    ],
)
logger = logging.getLogger(__name__)

# Audit logger
audit_logger = logging.getLogger("audit")
audit_handler = logging.FileHandler(CONFIG.audit_log_file)
audit_handler.setFormatter(logging.Formatter("%(asctime)s - %(message)s"))
audit_logger.addHandler(audit_handler)
audit_logger.setLevel(logging.INFO)
audit_logger.propagate = False

# =============================================================================
# RATE LIMITING
# =============================================================================

class RateLimiter:
    def __init__(self, max_per_minute: int, max_per_hour: int):
        self.max_per_minute = max_per_minute
        self.max_per_hour = max_per_hour
        self.requests: Dict[int, List[float]] = {}
    
    def check(self, user_id: int) -> bool:
        now = time.time()
        if user_id not in self.requests:
            self.requests[user_id] = []
        
        # Clean old requests
        self.requests[user_id] = [
            t for t in self.requests[user_id] if now - t < 3600
        ]
        
        # Check limits
        recent_minute = sum(1 for t in self.requests[user_id] if now - t < 60)
        recent_hour = len(self.requests[user_id])
        
        if recent_minute >= self.max_per_minute:
            return False
        if recent_hour >= self.max_per_hour:
            return False
        
        self.requests[user_id].append(now)
        return True

rate_limiter = RateLimiter(CONFIG.max_commands_per_minute, CONFIG.max_commands_per_hour)

# =============================================================================
# STATE MANAGEMENT
# =============================================================================

pending_disable_requests: Dict[int, Dict] = {}
request_counter = 1

def load_broadcast_list() -> List[int]:
    if CONFIG.broadcast_list_file.exists():
        try:
            with open(CONFIG.broadcast_list_file) as f:
                return json.load(f)
        except Exception:
            pass
    return []

def save_broadcast_list(chat_ids: List[int]) -> None:
    CONFIG.broadcast_list_file.parent.mkdir(parents=True, exist_ok=True)
    with open(CONFIG.broadcast_list_file, "w") as f:
        json.dump(list(set(chat_ids)), f)

def load_pending_requests() -> None:
    global pending_disable_requests, request_counter
    if CONFIG.pending_requests_file.exists():
        try:
            with open(CONFIG.pending_requests_file) as f:
                data = json.load(f)
                pending_disable_requests = {int(k): v for k, v in data.get("requests", {}).items()}
                request_counter = data.get("counter", 1)
        except Exception:
            pass

def save_pending_requests() -> None:
    CONFIG.pending_requests_file.parent.mkdir(parents=True, exist_ok=True)
    with open(CONFIG.pending_requests_file, "w") as f:
        json.dump({
            "requests": {str(k): v for k, v in pending_disable_requests.items()},
            "counter": request_counter
        }, f)

def audit_log(user_id: int, username: str, command: str, args: List[str], allowed: bool) -> None:
    audit_logger.info(
        f"user_id={user_id} username={username} command={command} "
        f"args={args} allowed={allowed}"
    )

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

async def run_command(cmd: List[str], timeout: int = 30) -> tuple[str, str, int]:
    """Run command asynchronously with timeout."""
    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        try:
            stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout)
            return stdout.decode().strip(), stderr.decode().strip(), proc.returncode
        except asyncio.TimeoutError:
            proc.kill()
            await proc.communicate()
            return "", "Command timed out", 124
    except Exception as e:
        logger.error(f"Command failed: {e}")
        return "", str(e), 1

async def get_system_stats() -> str:
    """Generate daily system report."""
    hostname = socket.gethostname()
    ip = subprocess.getoutput("hostname -I | awk '{print $1}'")
    uptime = subprocess.getoutput("uptime -p")
    
    try:
        temp = subprocess.getoutput("vcgencmd measure_temp").replace("temp=", "")
    except Exception:
        temp = "N/A"
    
    mem = psutil.virtual_memory()
    ram_usage = f"{mem.used // 1024 // 1024}Mi / {mem.total // 1024 // 1024}Gi"
    
    disk = psutil.disk_usage("/")
    disk_free_gb = round(disk.free / (1024**3), 1)
    disk_usage = f"{disk.percent}% Used ({disk_free_gb}G Free)"
    
    services = {
        "prometheus": "prometheus",
        "node_exporter": "node_exporter",
        "alertmanager": "alertmanager",
        "grafana-server": "grafana-server",
        "pihole-FTL": "pihole-FTL",
        "smbd": "smbd",
        "n8n": "n8n",
        "stirling-pdf": "stirling-pdf",
        "nginx": "nginx",
        "cockpit.socket": "cockpit.socket",
        "webmin": "webmin",
        "tailscale": "tailscale",
    }
    
    service_lines = []
    for name, svc in services.items():
        _, _, code = await run_command(["systemctl", "is-active", "--quiet", svc])
        is_active = code == 0
        icon = "✅" if is_active else "❌"
        service_lines.append(f"{icon} {name}")
    
    # Pi-hole stats
    pi_stats = ""
    try:
        stdout, _, code = await run_command(["pihole", "-c", "-j"])
        if code == 0:
            stats = json.loads(stdout)
            pi_stats = (
                f"\n🛡️ <b>Pi-hole Stats</b>\n"
                f"Queries: {stats.get('dns_queries_today', 'N/A')}\n"
                f"Blocked: {stats.get('ads_blocked_today', 'N/A')} ({stats.get('ads_percentage_today', 'N/A')}%)\n"
                f"Domains: {stats.get('domains_being_blocked', 'N/A')}\n"
                f"Status: {'Active ✅' if stats.get('status') == 'enabled' else 'Disabled ❌'}"
            )
    except Exception:
        pass
    
    report = (
        f"📊 <b>DAILY SYSTEM REPORT</b> 📊\n\n"
        f"<b>Host:</b> {hostname}\n"
        f"<b>IP:</b> {ip}\n"
        f"<b>Uptime:</b> {uptime}\n"
        f"<b>Temp:</b> {temp}\n"
        f"<b>RAM:</b> {ram_usage}\n"
        f"<b>Disk:</b> {disk_usage}{pi_stats}\n\n"
        f"<b>Services:</b>\n" + "\n".join(service_lines)
    )
    return report

def check_admin_access(chat_id: int) -> bool:
    return str(chat_id) == str(CONFIG.admin_chat_id)

def check_user_access(chat_id: int) -> bool:
    # User bot is public, but we track chat_ids for broadcasts
    return True

def validate_command_args(args: List[str], max_args: int = 5) -> bool:
    """Basic input validation."""
    if len(args) > max_args:
        return False
    for arg in args:
        # Prevent command injection
        if any(c in arg for c in [';', '&', '|', '$', '`', '>', '<', '\n', '\r']):
            return False
    return True

# =============================================================================
# USER BOT HANDLERS
# =============================================================================

async def user_start(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not check_user_access(update.effective_chat.id):
        return
    
    if not rate_limiter.check(update.effective_user.id):
        await update.message.reply_text("⏳ Rate limited. Please wait.")
        return
    
    chat_id = update.effective_chat.id
    existing = load_broadcast_list()
    if chat_id not in existing:
        existing.append(chat_id)
        save_broadcast_list(existing)
        logger.info(f"New User Bot subscriber: {chat_id}")
    
    await update.message.reply_text(
        "👋 Hello! I'm the Pi Server Status Bot.\n"
        "Commands:\n"
        "/status - System report\n"
        "/pihole_stats - Pi-hole statistics\n"
        "/pdr <duration> - Request Pi-hole disable (e.g., /pdr 10m)\n"
        "/help - Show this help"
    )
    audit_log(update.effective_user.id, update.effective_user.username or "unknown", "start", [], True)

async def user_status(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not check_user_access(update.effective_chat.id):
        return
    
    if not rate_limiter.check(update.effective_user.id):
        await update.message.reply_text("⏳ Rate limited.")
        return
    
    # Auto-register
    chat_id = update.effective_chat.id
    existing = load_broadcast_list()
    if chat_id not in existing:
        existing.append(chat_id)
        save_broadcast_list(existing)
    
    report = await get_system_stats()
    await update.message.reply_text(report, parse_mode=ParseMode.HTML)
    audit_log(update.effective_user.id, update.effective_user.username or "unknown", "status", [], True)

async def user_pihole_stats(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not check_user_access(update.effective_chat.id):
        return
    
    if not rate_limiter.check(update.effective_user.id):
        await update.message.reply_text("⏳ Rate limited.")
        return
    
    try:
        stdout, _, code = await run_command(["pihole", "-c", "-j"])
        if code != 0:
            raise Exception(stdout)
        stats = json.loads(stdout)
        
        summary = (
            f"🛡️ <b>Pi-hole Status</b>\n\n"
            f"Queries Today: {stats.get('dns_queries_today', 'N/A')}\n"
            f"Ads Blocked: {stats.get('ads_blocked_today', 'N/A')}\n"
            f"Percentage: {stats.get('ads_percentage_today', 'N/A')}%\n"
            f"Domains Blocked: {stats.get('domains_being_blocked', 'N/A')}\n"
            f"Status: {'Active ✅' if stats.get('status') == 'enabled' else 'Disabled ❌'}"
        )
        await update.message.reply_text(summary, parse_mode=ParseMode.HTML)
    except Exception as e:
        await update.message.reply_text(f"❌ Error: {e}")
    audit_log(update.effective_user.id, update.effective_user.username or "unknown", "pihole_stats", [], True)

async def user_pdr(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Pi-hole Disable Request"""
    global request_counter
    
    if not check_user_access(update.effective_chat.id):
        return
    
    if not rate_limiter.check(update.effective_user.id):
        await update.message.reply_text("⏳ Rate limited.")
        return
    
    if not CONFIG.admin_token or not CONFIG.admin_chat_id:
        await update.message.reply_text("❌ Admin bot not configured. Cannot process request.")
        return
    
    chat_id = update.effective_chat.id
    username = update.effective_user.first_name or "Unknown"
    duration = context.args[0] if context.args else "5m"
    
    # Validate duration format
    import re
    if not re.match(r'^\d+[smhd]$', duration):
        await update.message.reply_text("❌ Invalid duration. Use format: 5m, 1h, 2d, etc.")
        return
    
    req_id = request_counter
    request_counter += 1
    
    pending_disable_requests[req_id] = {
        "chat_id": chat_id,
        "duration": duration,
        "requester_name": username,
        "timestamp": datetime.now().isoformat(),
    }
    save_pending_requests()
    
    await update.message.reply_text(f"⏳ Request #{req_id} sent to Admin (Disable Pi-hole for {duration})")
    
    # Notify Admin Bot
    try:
        admin_bot = Bot(token=CONFIG.admin_token)
        admin_msg = (
            f"🚨 <b>DISABLE REQUEST</b> 🚨\n\n"
            f"ID: #{req_id}\n"
            f"User: {username}\n"
            f"Duration: {duration}\n\n"
            f"Use <code>/approve {req_id}</code> or <code>/deny {req_id}</code>"
        )
        await admin_bot.send_message(
            chat_id=CONFIG.admin_chat_id,
            text=admin_msg,
            parse_mode=ParseMode.HTML
        )
    except Exception as e:
        logger.error(f"Failed to notify Admin: {e}")
        await update.message.reply_text(f"⚠️ Warning: Could not forward to Admin.\nError: {e}")
    
    audit_log(update.effective_user.id, username, "pdr", [duration], True)

async def user_help(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    await update.message.reply_text(
        "🤖 <b>Pi Server Bot Help</b>\n\n"
        "<b>User Commands:</b>\n"
        "/start - Register for notifications\n"
        "/status - Full system report\n"
        "/pihole_stats - Pi-hole statistics\n"
        "/pdr <duration> - Request Pi-hole disable (e.g., /pdr 10m)\n"
        "/help - This message",
        parse_mode=ParseMode.HTML
    )

# =============================================================================
# ADMIN BOT HANDLERS
# =============================================================================

async def admin_check(update: Update) -> bool:
    if not check_admin_access(update.effective_chat.id):
        audit_log(
            update.effective_user.id,
            update.effective_user.username or "unknown",
            "unauthorized_access",
            [update.message.text or ""],
            False
        )
        await update.message.reply_text("❌ Unauthorized. Admin only.")
        return False
    return True

async def admin_reboot(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not await admin_check(update):
        return
    if not validate_command_args(context.args):
        await update.message.reply_text("❌ Invalid arguments")
        return
    
    await update.message.reply_text("⚠️ Rebooting in 5 seconds...")
    await asyncio.sleep(5)
    await run_command(["sudo", "reboot"])
    audit_log(update.effective_user.id, update.effective_user.username or "unknown", "reboot", [], True)

async def admin_shutdown(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not await admin_check(update):
        return
    await update.message.reply_text("⚠️ Shutting down in 5 seconds...")
    await asyncio.sleep(5)
    await run_command(["sudo", "shutdown", "now"])
    audit_log(update.effective_user.id, update.effective_user.username or "unknown", "shutdown", [], True)

async def admin_restart(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not await admin_check(update):
        return
    if not context.args or not validate_command_args(context.args):
        await update.message.reply_text("Usage: /restart <service_name>")
        return
    
    service = context.args[0]
    # Validate service name (alphanumeric, dash, underscore, dot)
    import re
    if not re.match(r'^[a-zA-Z0-9._-]+$', service):
        await update.message.reply_text("❌ Invalid service name")
        return
    
    await update.message.reply_text(f"🔄 Restarting {service}...")
    _, _, code = await run_command(["sudo", "systemctl", "restart", service])
    
    if code == 0:
        await update.message.reply_text(f"✅ {service} restarted")
    else:
        await update.message.reply_text(f"❌ Failed to restart {service}")
    audit_log(update.effective_user.id, update.effective_user.username or "unknown", "restart", [service], code == 0)

async def admin_pihole(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not await admin_check(update):
        return
    if not context.args or context.args[0] not in ["enable", "disable"]:
        await update.message.reply_text("Usage: /pihole <enable|disable> [duration]")
        return
    if not validate_command_args(context.args):
        await update.message.reply_text("❌ Invalid arguments")
        return
    
    cmd = context.args[0]
    full_cmd = ["pihole", cmd]
    if len(context.args) > 1:
        full_cmd.append(context.args[1])
    
    await update.message.reply_text(f"🛡️ Running: pihole {cmd}...")
    stdout, stderr, code = await run_command(full_cmd)
    
    if code == 0:
        await update.message.reply_text(f"✅ Done:\n<code>{stdout}</code>", parse_mode=ParseMode.HTML)
    else:
        await update.message.reply_text(f"❌ Failed:\n<code>{stderr or stdout}</code>", parse_mode=ParseMode.HTML)
    audit_log(update.effective_user.id, update.effective_user.username or "unknown", "pihole", context.args, code == 0)

async def admin_approve(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not await admin_check(update):
        return
    if not context.args or not validate_command_args(context.args):
        await update.message.reply_text("Usage: /approve <req_id>")
        return
    
    load_pending_requests()
    
    try:
        req_id = int(context.args[0].replace("#", ""))
    except ValueError:
        await update.message.reply_text("❌ Invalid Request ID")
        return
    
    req = pending_disable_requests.pop(req_id, None)
    if not req:
        await update.message.reply_text("❌ Request not found or already handled")
        return
    
    save_pending_requests()
    
    # Execute
    duration = req["duration"]
    _, _, code = await run_command(["pihole", "disable", duration])
    
    if code == 0:
        await update.message.reply_text(f"✅ Approved #{req_id}. Pi-hole disabled for {duration}")
    else:
        await update.message.reply_text(f"❌ Approved but command failed")
    
    # Notify user
    if CONFIG.user_token:
        try:
            user_bot = Bot(token=CONFIG.user_token)
            await user_bot.send_message(
                chat_id=req["chat_id"],
                text=f"✅ Your request to disable Pi-hole for {duration} was <b>APPROVED</b>.",
                parse_mode=ParseMode.HTML
            )
        except Exception as e:
            logger.error(f"Failed to notify user: {e}")
    
    audit_log(update.effective_user.id, update.effective_user.username or "unknown", "approve", [str(req_id)], True)

async def admin_deny(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not await admin_check(update):
        return
    if not context.args or not validate_command_args(context.args):
        await update.message.reply_text("Usage: /deny <req_id>")
        return
    
    load_pending_requests()
    
    try:
        req_id = int(context.args[0].replace("#", ""))
    except ValueError:
        await update.message.reply_text("❌ Invalid Request ID")
        return
    
    req = pending_disable_requests.pop(req_id, None)
    if not req:
        await update.message.reply_text("❌ Request not found")
        return
    
    save_pending_requests()
    await update.message.reply_text(f"❌ Denied #{req_id}")
    
    # Notify user
    if CONFIG.user_token:
        try:
            user_bot = Bot(token=CONFIG.user_token)
            await user_bot.send_message(
                chat_id=req["chat_id"],
                text="❌ Your Pi-hole disable request was <b>DENIED</b>.",
                parse_mode=ParseMode.HTML
            )
        except Exception:
            pass
    
    audit_log(update.effective_user.id, update.effective_user.username or "unknown", "deny", [str(req_id)], True)

async def admin_announce(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not await admin_check(update):
        return
    if not context.args:
        await update.message.reply_text("Usage: /announce <message>")
        return
    
    message = " ".join(context.args)
    if not validate_command_args([message], max_args=1):
        await update.message.reply_text("❌ Invalid message")
        return
    
    subscribers = load_broadcast_list()
    if not subscribers:
        await update.message.reply_text("No subscribers")
        return
    
    if not CONFIG.user_token:
        await update.message.reply_text("❌ User bot token not configured")
        return
    
    user_bot = Bot(token=CONFIG.user_token)
    sent = 0
    formatted = f"📢 <b>ANNOUNCEMENT</b>\n\n{message}"
    
    for chat_id in subscribers:
        try:
            await user_bot.send_message(chat_id=chat_id, text=formatted, parse_mode=ParseMode.HTML)
            sent += 1
        except Exception:
            pass
    
    await update.message.reply_text(f"✅ Sent to {sent}/{len(subscribers)} subscribers")
    audit_log(update.effective_user.id, update.effective_user.username or "unknown", "announce", [message[:50]], True)

async def admin_pdr(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    """Admin shortcut to disable Pi-hole"""
    if not await admin_check(update):
        return
    if not validate_command_args(context.args):
        await update.message.reply_text("❌ Invalid arguments")
        return
    
    duration = context.args[0] if context.args else "5m"
    import re
    if not re.match(r'^\d+[smhd]$', duration):
        await update.message.reply_text("❌ Invalid duration format")
        return
    
    await update.message.reply_text(f"⏳ Disabling Pi-hole for {duration}...")
    _, _, code = await run_command(["pihole", "disable", duration])
    
    if code == 0:
        await update.message.reply_text(f"✅ Pi-hole disabled for {duration}")
    else:
        await update.message.reply_text("❌ Failed")
    audit_log(update.effective_user.id, update.effective_user.username or "unknown", "pdr", [duration], code == 0)

async def admin_status(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not await admin_check(update):
        return
    report = await get_system_stats()
    await update.message.reply_text(report, parse_mode=ParseMode.HTML)
    audit_log(update.effective_user.id, update.effective_user.username or "unknown", "status", [], True)

async def admin_pihole_stats(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not await admin_check(update):
        return
    await user_pihole_stats(update, context)

# =============================================================================
# MAIN APPLICATION
# =============================================================================

async def main() -> None:
    if not CONFIG.admin_token and not CONFIG.user_token:
        logger.error("No bot tokens configured")
        return
    
    load_pending_requests()
    
    # Build applications
    apps = []
    
    if CONFIG.user_token:
        user_app = Application.builder().token(CONFIG.user_token).build()
        user_app.add_handler(CommandHandler("start", user_start))
        user_app.add_handler(CommandHandler("status", user_status))
        user_app.add_handler(CommandHandler("pihole_stats", user_pihole_stats))
        user_app.add_handler(CommandHandler("pdr", user_pdr))
        user_app.add_handler(CommandHandler("help", user_help))
        apps.append(("User", user_app))
    
    if CONFIG.admin_token:
        admin_app = Application.builder().token(CONFIG.admin_token).build()
        admin_app.add_handler(CommandHandler("reboot", admin_reboot))
        admin_app.add_handler(CommandHandler("shutdown", admin_shutdown))
        admin_app.add_handler(CommandHandler("restart", admin_restart))
        admin_app.add_handler(CommandHandler("pihole", admin_pihole))
        admin_app.add_handler(CommandHandler("status", admin_status))
        admin_app.add_handler(CommandHandler("pihole_stats", admin_pihole_stats))
        admin_app.add_handler(CommandHandler("approve", admin_approve))
        admin_app.add_handler(CommandHandler("deny", admin_deny))
        admin_app.add_handler(CommandHandler("announce", admin_announce))
        admin_app.add_handler(CommandHandler("pdr", admin_pdr))
        apps.append(("Admin", admin_app))
    
    # Start all
    for name, app in apps:
        await app.initialize()
        await app.start()
        await app.updater.start_polling(drop_pending_updates=True)
        logger.info(f"{name} Bot started")
    
    # Keep running
    try:
        await asyncio.Event().wait()
    finally:
        for name, app in apps:
            await app.updater.stop()
            await app.stop()
            await app.shutdown()

if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        logger.info("Shutting down...")
PYTHON_SCRIPT

    chmod 750 "${BOT_SCRIPT}"
    chown "${SERVICE_USER}:${SERVICE_USER}" "${BOT_SCRIPT}"
    
    log_success "Bot script deployed"
}

install_systemd_service() {
    log_info "Installing systemd service..."
    
    cat > /etc/systemd/system/telegram-bot.service <<EOF
[Unit]
Description=Pi Server Dual Telegram Bot
Documentation=https://github.com/your-repo/InitOps
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${APP_DIR}
EnvironmentFile=-/etc/InitOps/settings.conf
ExecStart=${VENV_DIR}/bin/python ${BOT_SCRIPT}
Restart=always
RestartSec=10
StartLimitInterval=60
StartLimitBurst=3

# Security hardening
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=${APP_DIR} /var/log/pi-server-bot
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictRealtime=yes
RestrictNamespaces=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
SystemCallFilter=@system-service
SystemCallErrorNumber=EPERM

# Resource limits
LimitNOFILE=65536
LimitNPROC=512
MemoryMax=512M
CPUQuota=50%

[Install]
WantedBy=multi-user.target
EOF
    
    # Create log directory
    mkdir -p /var/log/pi-server-bot
    chown "${SERVICE_USER}:${SERVICE_USER}" /var/log/pi-server-bot
    chmod 750 /var/log/pi-server-bot
    
    # Create settings symlink for EnvironmentFile
    mkdir -p /etc/InitOps
    if [[ -f "${SCRIPT_DIR}/../settings.conf" ]]; then
        ln -sf "${SCRIPT_DIR}/../settings.conf" /etc/InitOps/settings.conf
    fi
    
    systemctl daemon-reload
    systemctl enable telegram-bot
    systemctl restart telegram-bot
    
    sleep 3
    if systemctl is-active --quiet telegram-bot; then
        log_success "Telegram Bot service running"
    else
        log_error "Telegram Bot failed to start"
        systemctl status telegram-bot --no-pager
        return 1
    fi
}

configure_logrotate() {
    log_info "Configuring logrotate for bot logs..."
    
    cat > /etc/logrotate.d/pi-server-bot <<EOF
/var/log/pi-server-bot/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    create 640 ${SERVICE_USER} ${SERVICE_USER}
    sharedscripts
    postrotate
        systemctl reload telegram-bot >/dev/null 2>&1 || true
    endscript
}
EOF
    
    log_success "Logrotate configured"
}

# Run
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
main "$@"