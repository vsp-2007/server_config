#!/bin/bash
set -e

APP_DIR="/opt/pi-server-bot"
VENV_DIR="$APP_DIR/venv"
SCRIPT_SRC="scripts/bot/dual_bot.py"
SCRIPT_DEST="$APP_DIR/dual_bot.py"
SERVICE_SRC="systemd/telegram_bot.service"
SERVICE_DEST="/etc/systemd/system/telegram_bot.service"

echo "--- Installing Dual Telegram Bot ---"

# 1. Create Directory
if [ ! -d "$APP_DIR" ]; then
    echo "Creating directory: $APP_DIR"
    mkdir -p "$APP_DIR"
fi

# 2. Setup Virtual Environment
if [ ! -d "$VENV_DIR" ]; then
    echo "Creating Python Virtual Environment..."
    apt-get update -qq && apt-get install -y python3-venv
    python3 -m venv "$VENV_DIR"
fi

# 3. Install Python Dependencies
echo "Installing Python libraries (python-telegram-bot, psutil)..."
"$VENV_DIR/bin/pip" install --upgrade pip
"$VENV_DIR/bin/pip" install python-telegram-bot psutil

# 4. Copy Script
echo "Deploying bot script..."
cp "$SCRIPT_SRC" "$SCRIPT_DEST"
chmod 700 "$APP_DIR"  # Secure directory (Root only)
chmod 600 "$SCRIPT_DEST" # Secure script

# 5. Install Systemd Service
echo "Configuring Systemd Service..."
cp "$SERVICE_SRC" "$SERVICE_DEST"

# Dynamic Config Path Injection
# Using the absolute path of the current directory where the script is run (should be the Interactive-server_config_script root containing setup.conf)
REAL_CONFIG="$(pwd)/setup.conf"
echo "Updating EnvironmentFile path to: $REAL_CONFIG"
sed -i "s|EnvironmentFile=.*|EnvironmentFile=$REAL_CONFIG|" "$SERVICE_DEST"

systemctl daemon-reload
systemctl enable telegram_bot.service
systemctl restart telegram_bot.service

echo "✅ Telegram Bot Installed & Restarted."
