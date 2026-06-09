# Intractive Server Setup script for debian based systems
# Initially developed for raspberry pi os (trixie) on a arm64(Aarch64) device
Note:-
>_there might be compatablity issues with other debian based distros_.
> And some package and application might not work or install due to  architectural mismatches(Aarch64-Aarch32-x86-x64) 

Welcome to the **Server Setup** project. The objective of this project is to transform a standard Raspberry Pi OS (Trixie) installation into a powerful, automated, and observable server stack.

## 🚀 Features

This server stack comes packed with a highly modular and robust ecosystem:
- **Core System**: Automated user setup, SSH configuration, and optimization.
- **Network & VPN**: Tailscale integration for secure remote management.
- **Pi-hole**: Network-wide DNS ad-blocker & resolver.
- **Monitoring Stack**: Prometheus, node-exporter, Alertmanager, and Grafana for full observability.
- **Storage & Management**: Samba for file sharing, paired with Webmin for a GUI administration panel.
- **Telegram Bot**: Dual-bot architecture for interactive server management and receiving alerts.
- **Reverse Proxy**: Nginx integration for local domain routing (e.g. `dashboard.home`, `pi.home`).
- **Additional Apps**: Cockpit, Localsend, Stirling-PDF, and n8n Automation Engine.

## 📚 Documentation
For complete technical details, see `DOCUMENTATION.md`, or check the `docs/` and `documents/` directories.

## 🛠️ Usage
# Installation Steps

This guide explains how to install the Pi Server Setup suite using the provided orchestration script.

## Pre-requisites
- A clean installation of Raspberry Pi OS (Trixie).
- SSH access to your Raspberry Pi.
- Basic networking setup completed (e.g. connected to your WiFi or Ethernet).

## 🚀 How to Install

1. **Clone the Repository** (If you haven't already):
   Ensure you have downloaded this project to your Raspberry Pi.
   
2. **Make the Script Executable**:
   Navigate to the project directory and make the master installer executable:
   ```bash
   chmod +x install.sh
   ```

3. **Run the Master Installer**:
   Execute the installation script as `root`:
   ```bash
   sudo ./install.sh
   ```

4. **Follow the Interactive Menu**:
   You will be presented with the following options:
   ```text
   1) System Basics (Update, User, SSH, Tools)
   2) Network (Tailscale, Static IP Helper)
   3) Pi-hole (Ad Blocking)
   4) Monitoring Stack (Prometheus, Grafana, Alertmanager)
   5) File Sharing (Samba, Webmin)
   6) Utilities
   7) Telegram Bot
   8) Localsend (File Sharing App)
   9) Stirling-PDF (PDF Tools)
   10) Nginx Reverse Proxy (Domain Access)
   11) Cockpit (Web-based Administration)
   12) n8n Automation Engine
   A) Install Everything
   Q) Quit
   ```

   Select the numbers you wish to install, or press `A` to install the full stack.

5. **Provide Interactive Configuration**:
   During the setup, you might be asked for credentials such as:
   - System User (`PI_USER`)
   - Grafana Admin Password
   - Telegram Bot Tokens and Chat IDs
   - Samba User Configuration

6. **Review the Summary**:
   Once the script completes, it will display an **Installation Summary** detailing the specific IP addresses, local domain URLs, and ports for accessing each installed server component.
