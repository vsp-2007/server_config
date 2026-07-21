# GUI Implementation Guide for Pi Server Setup v2

## Overview

This document explores GUI implementation options for the InitOps project, allowing users to configure and run the installer through a graphical interface instead of CLI-only interaction.

---

## Current State

The project currently uses:
- **CLI-only**: `sudo ./install.sh` with interactive prompts
- **Config file**: `settings.conf` (shell-style key=value)
- **Module selection**: Text-based menu with numbers
- **Validation**: Input validation with retry loops

---

## GUI Implementation Options

### Option 1: Terminal-Based TUI (Text User Interface) - RECOMMENDED START

**Tools**: `dialog`, `whiptail`, `newt`, `bashplotlib`

**Pros**:
- Runs in SSH/terminal (no X11/Wayland needed)
- Works over serial console, VM console, SSH
- Lightweight, no extra dependencies on headless systems
- Matches current workflow (terminal-based)
- Can be invoked with `sudo ./install.sh --tui`

**Cons**:
- Limited visual polish
- No mouse support in some terminals
- Form validation limited

**Implementation**:
```bash
# Using whiptail (usually pre-installed on Debian)
MODULES=$(whiptail --title "Pi Server Setup" --checklist \
    "Select modules to install:" 20 78 10 \
    "system" "System Basics" ON \
    "network" "Tailscale + Firewall" ON \
    "pihole" "Pi-hole DNS" ON \
    "monitoring" "Prometheus/Grafana" ON \
    3>&1 1>&2 2>&3)
```

**Dependencies**: `whiptail` (pre-installed), `dialog` (optional, more features)

---

### Option 2: Web-Based Configuration UI - RECOMMENDED FOR PRODUCTION

**Architecture**: Local web server (Python Flask/FastAPI, Node.js, or Go) serving a React/Vue/Svelte frontend

**Pros**:
- Rich UI with real-time validation
- Works from any browser (phone, laptop)
- Can run on the target machine during install
- Supports file upload for SSH keys
- Progress bars, logs, real-time status via WebSocket
- Can persist draft configs

**Cons**:
- Requires web server runtime during install
- More complex implementation
- Security considerations (auth, HTTPS)
- Extra dependencies

**Recommended Stack**:
```
Backend:  Python 3.11+ + FastAPI + uvicorn
Frontend: React 18 + TypeScript + Vite + Tailwind CSS
Auth:     Session-based with CSRF, or simple token
WS:       WebSocket for real-time install logs
```

**Port**: 8443 (HTTPS) or 8080 (HTTP with Tailscale)

**Directory Structure**:
```
/opt/pi-server-gui/
├── backend/
│   ├── main.py          # FastAPI app
│   ├── config.py        # Config models (Pydantic)
│   ├── installer.py     # Wrapper around install.sh
│   ├── websocket.py     # Real-time logs
│   └── auth.py          # Simple token auth
├── frontend/
│   ├── src/
│   │   ├── components/  # React components
│   │   ├── pages/       # Config, Modules, Progress, Summary
│   │   └── api.ts       # API client
│   └── dist/            # Built assets
├── templates/
│   └── index.html       # Serves frontend
└── run_gui.sh           # Launcher script
```

**Auto-start on install**:
```bash
# In install.sh --gui mode
if [[ "${GUI_MODE}" == "true" ]]; then
    start_gui_server
    echo "Open https://$(hostname -I | awk '{print $1}'):8443"
    wait_for_gui_completion
fi
```

---

### Option 3: Desktop Application (Electron/Tauri)

**Pros**:
- Native desktop experience
- Can run on user's laptop, SSH to target
- Good for offline config preparation

**Cons**:
- Large bundle size
- Requires building for each platform
- Overkill for server setup

**Better Alternative**: Tauri (Rust + WebView) - smaller, native

---

### Option 4: Hybrid Approach (Best of Both Worlds)

```
┌─────────────────────────────────────────────────────────────┐
│                    InitOps v2 GUI                   │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐     │
│  │  CLI/TUI    │    │  Web UI     │    │  Desktop    │     │
│  │  (Default)  │    │  (--gui)    │    │  (Future)   │     │
│  └──────┬──────┘    └──────┬──────┘    └──────┬──────┘     │
│         │                  │                  │             │
│         └──────────────────┼──────────────────┘             │
│                            ▼                                 │
│                 ┌─────────────────────┐                      │
│                 │   Shared Backend    │                      │
│                 │  (install.sh core)  │                      │
│                 └─────────────────────┘                      │
└─────────────────────────────────────────────────────────────┘
```

---

## Recommended Implementation Plan

### Phase 1: Enhanced TUI (Week 1-2) - Immediate Value

**File**: `scripts/gui/tui_install.sh` (called via `install.sh --tui`)

```bash
#!/bin/bash
# TUI installer using whiptail/dialog

# Check for dialog/whiptail
if command -v dialog >/dev/null; then TOOL=dialog; elif command -v whiptail >/dev/null; then TOOL=whiptail; else apt-get install -y dialog; TOOL=dialog; fi

# Module selection checklist
MODULES=$($TOOL --title "Pi Server Setup v2" --checklist \
    "Select modules to install (Space to toggle, Enter to confirm):" \
    20 78 12 \
    "system" "System Basics (Required)" ON \
    "network" "Tailscale + Firewall" ON \
    "pihole" "Pi-hole DNS Ad-blocking" ON \
    "monitoring" "Prometheus + Grafana" ON \
    "samba" "Samba + Webmin" OFF \
    "utils" "Reports + Cron" ON \
    "telegram" "Dual Telegram Bot" OFF \
    "localsend" "LocalSend File Sharing" OFF \
    "stirling" "Stirling-PDF" OFF \
    "nginx" "Nginx Reverse Proxy" OFF \
    "cockpit" "Cockpit Web Admin" OFF \
    "n8n" "n8n Automation" OFF \
    3>&1 1>&2 2>&3)

# Config form with validation
CONFIG=$($TOOL --title "Configuration" --form \
    "Enter required configuration:" 20 70 8 \
    "PI_USER:"        1 1 "piadmin"   1 15 20 0 \
    "SSH_PORT:"       2 1 "2222"      2 15 10 0 \
    "TELEGRAM_TOKEN:" 3 1 ""          3 15 50 0 \
    "TAILSCALE_KEY:"  4 1 ""          4 15 50 0 \
    3>&1 1>&2 2>&3)

# Parse and write to settings.conf
```

**Integration**: Add `--tui` flag to `install.sh`

---

### Phase 2: Web UI (Week 3-5) - Full Featured

**Backend (FastAPI)** - `/opt/pi-server-gui/backend/main.py`:

```python
from fastapi import FastAPI, WebSocket, Form, HTTPException
from fastapi.staticfiles import StaticFiles
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, validator
from typing import List, Optional
import subprocess, asyncio, json, os
from pathlib import Path

app = FastAPI()

class ConfigModel(BaseModel):
    PI_USER: str = "piadmin"
    PI_PASSWORD: Optional[str] = None
    SSH_PORT: int = 2222
    SSH_PASSWORD_AUTH: str = "no"
    PI_SSH_KEYS: Optional[str] = None
    TELEGRAM_ADMIN_TOKEN: Optional[str] = None
    TELEGRAM_ADMIN_CHAT_ID: Optional[str] = None
    TELEGRAM_USER_TOKEN: Optional[str] = None
    TELEGRAM_USER_CHAT_ID: Optional[str] = None
    TAILSCALE_AUTH_KEY: Optional[str] = None
    TAILSCALE_EXIT_NODE: bool = False
    STATIC_IP: Optional[str] = None
    STATIC_GATEWAY: Optional[str] = None
    STATIC_DNS: str = "1.1.1.1"
    GRAFANA_ADMIN_PASSWORD: Optional[str] = None
    PIHOLE_PASSWORD: Optional[str] = None
    SMB_PASSWORD: Optional[str] = None
    SMB_USER: str = "smbuser"
    SMB_SHARE_NAME: str = "pishare"
    WEBMIN_ENABLED: bool = True

class InstallRequest(BaseModel):
    modules: List[str]
    config: ConfigModel

# Serve React frontend
app.mount("/assets", StaticFiles(directory="frontend/dist/assets"), name="assets")

@app.get("/", response_class=HTMLResponse)
async def index():
    return Path("frontend/dist/index.html").read_text()

@app.get("/api/modules")
async def get_modules():
    return {
        "system": {"name": "System Basics", "required": True, "description": "Updates, User, SSH, Hardening"},
        "network": {"name": "Network", "required": False, "description": "Tailscale, Firewall, Fail2Ban"},
        "pihole": {"name": "Pi-hole", "required": False, "description": "DNS Ad-blocking"},
        "monitoring": {"name": "Monitoring", "required": False, "description": "Prometheus, Grafana, Alertmanager"},
        "samba": {"name": "File Sharing", "required": False, "description": "Samba, Webmin"},
        "utils": {"name": "Utilities", "required": False, "description": "Reports, Cron, Maintenance"},
        "telegram": {"name": "Telegram Bot", "required": False, "description": "Dual Bot (Admin + User)"},
        "localsend": {"name": "LocalSend", "required": False, "description": "File Sharing App"},
        "stirling": {"name": "Stirling-PDF", "required": False, "description": "PDF Tools"},
        "nginx": {"name": "Reverse Proxy", "required": False, "description": "Nginx + .home domains"},
        "cockpit": {"name": "Cockpit", "required": False, "description": "Web Admin"},
        "n8n": {"name": "n8n Automation", "required": False, "description": "Workflow Engine"},
    }

@app.post("/api/validate")
async def validate_config(config: ConfigModel):
    errors = []
    if not config.PI_USER or not config.PI_USER.islower():
        errors.append("PI_USER must be lowercase")
    if config.SSH_PORT < 1 or config.SSH_PORT > 65535:
        errors.append("Invalid SSH port")
    return {"valid": len(errors) == 0, "errors": errors}

@app.post("/api/install")
async def start_install(request: InstallRequest, websocket: WebSocket = None):
    # Write settings.conf
    config_lines = []
    for field, value in request.config.dict().items():
        if value is not None:
            config_lines.append(f'{field}="{value}"')
    Path("settings.conf").write_text("\n".join(config_lines) + "\n")
    os.chmod("settings.conf", 0o600)
    
    # Run install.sh with progress via WebSocket
    modules = ",".join(request.modules)
    proc = await asyncio.create_subprocess_exec(
        "sudo", "./install.sh", "-y", "-m", modules,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT
    )
    
    async for line in proc.stdout:
        if websocket:
            await websocket.send_text(json.dumps({"type": "log", "data": line.decode()}))
    
    await proc.wait()
    return {"success": proc.returncode == 0}

@app.websocket("/ws/install")
async def ws_install(websocket: WebSocket):
    await websocket.accept()
    # Handle real-time install progress
    try:
        while True:
            data = await websocket.receive_text()
            msg = json.loads(data)
            if msg["type"] == "start":
                await start_install_with_ws(msg["request"], websocket)
    except Exception:
        pass
```

**Frontend (React + TypeScript)** - Key Components:

```typescript
// pages/Config.tsx
const ConfigPage = () => {
  const [config, setConfig] = useState<ConfigModel>(defaults);
  const [errors, setErrors] = useState<string[]>([]);
  
  const validate = async () => {
    const res = await api.post('/api/validate', config);
    setErrors(res.data.errors);
    return res.data.valid;
  };
  
  return (
    <Form onSubmit={handleSubmit}>
      <Field name="PI_USER" label="System Username" required />
      <Field name="SSH_PORT" label="SSH Port" type="number" min={1} max={65535} />
      <Field name="PI_PASSWORD" label="System Password" type="password" 
             help="Leave empty to auto-generate" />
      <Field name="TELEGRAM_ADMIN_TOKEN" label="Telegram Admin Token" 
             help="From @BotFather" />
      <Field name="TELEGRAM_ADMIN_CHAT_ID" label="Admin Chat ID" 
             help="From @userinfobot" />
      <Field name="TAILSCALE_AUTH_KEY" label="Tailscale Auth Key" 
             help="Optional: for unattended setup" />
      <Button onClick={handleNext}>Next: Select Modules</Button>
    </Form>
  );
};

// pages/Modules.tsx
const ModuleSelection = () => {
  const [modules, setModules] = useState<Record<string, boolean>>({});
  const [moduleInfo, setModuleInfo] = useState<ModuleInfo[]>([]);
  
  useEffect(() => {
    api.get('/api/modules').then(setModuleInfo);
  }, []);
  
  return (
    <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
      {moduleInfo.map(m => (
        <Card key={m.id} className={modules[m.id] ? 'ring-2 ring-blue-500' : ''}
             onClick={() => setModules({...modules, [m.id]: !modules[m.id]})}>
          <input type="checkbox" checked={modules[m.id]} readOnly />
          <h3>{m.name}</h3>
          <p className="text-sm text-gray-500">{m.description}</p>
          {m.required && <Badge>Required</Badge>}
        </Card>
      ))}
    </div>
  );
};

// pages/Progress.tsx
const ProgressPage = () => {
  const [logs, setLogs] = useState<string[]>([]);
  const [progress, setProgress] = useState(0);
  const ws = useRef<WebSocket>();
  
  useEffect(() => {
    ws.current = new WebSocket(`wss://${location.host}/ws/install`);
    ws.current.onmessage = (e) => {
      const msg = JSON.parse(e.data);
      if (msg.type === 'log') setLogs(l => [...l, msg.data]);
      if (msg.type === 'progress') setProgress(msg.percent);
    };
  }, []);
  
  return (
    <div className="h-full flex flex-col">
      <ProgressBar value={progress} />
      <div className="flex-1 overflow-auto font-mono text-sm">
        {logs.map((l, i) => <div key={i}>{l}</div>)}
      </div>
    </div>
  );
};
```

---

### Phase 3: Desktop App (Future - Tauri)

```rust
// src-tauri/src/main.rs
use tauri::{Manager, Window};

fn main() {
    tauri::Builder::default()
        .setup(|app| {
            let window = WindowBuilder::new(app, "main", WindowUrl::App("index.html".into()))
                .title("Pi Server Setup")
                .inner_size(900.0, 700.0)
                .resizable(true)
                .build()?;
            
            // Inject install.sh as sidecar
            #[cfg(debug_assertions)]
            window.open_devtools();
            
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            run_install,
            validate_config,
            get_modules,
            save_config
        ])
        .run(tauri::generate_context!())
        .expect("error running tauri");
}

#[tauri::command]
async fn run_install(modules: Vec<String>, config: serde_json::Value) -> Result<String, String> {
    // Write settings.conf, spawn install.sh as child process
    // Stream stdout/stderr back to frontend via Tauri events
}
```

---

## Security Considerations for Web GUI

| Concern | Mitigation |
|---------|------------|
| **Auth** | Simple token displayed on first run; or SSH key auth |
| **HTTPS** | Self-signed cert + trust on first use; or Caddy auto-HTTPS |
| **CSRF** | SameSite cookies + CSRF tokens |
| **Input Validation** | Pydantic models + server-side validation |
| **Command Injection** | Never shell-interpolate; use `subprocess.exec` with args array |
| **Privilege Escalation** | GUI runs as user, only `install.sh` runs via `sudo` |
| **Secrets in Memory** | Clear tokens after install; don't log secrets |

---

## File Structure for GUI Implementation

```
InitOps/
├── install.sh                 # Main CLI (supports --tui, --gui)
├── scripts/
│   ├── gui/
│   │   ├── tui_install.sh     # Phase 1: whiptail TUI
│   │   └── web_gui/           # Phase 2: Web UI
│   │       ├── backend/
│   │       │   ├── main.py
│   │       │   ├── installer.py
│   │       │   ├── models.py
│   │       │   ├── websocket.py
│   │       │   ├── auth.py
│   │       │   └── requirements.txt
│   │       ├── frontend/
│   │       │   ├── package.json
│   │       │   ├── tsconfig.json
│   │       │   ├── vite.config.ts
│   │       │   ├── index.html
│   │       │   ├── src/
│   │       │   │   ├── main.tsx
│   │       │   │   ├── App.tsx
│   │       │   │   ├── api.ts
│   │       │   │   ├── components/
│   │       │   │   │   ├── Field.tsx
│   │       │   │   │   ├── ModuleCard.tsx
│   │       │   │   │   ├── ProgressBar.tsx
│   │       │   │   │   └── LogView.tsx
│   │       │   │   ├── pages/
│   │       │   │   │   ├── Config.tsx
│   │       │   │   │   ├── Modules.tsx
│   │       │   │   │   ├── Progress.tsx
│   │       │   │   │   └── Summary.tsx
│   │       │   │   ├── hooks/
│   │       │   │   │   ├── useWebSocket.ts
│   │       │   │   │   └── useInstall.ts
│   │       │   │   └── types.ts
│   │       │   └── dist/       # Built assets (committed)
│   │       ├── run_gui.sh      # Launcher
│   │       └── Dockerfile      # Optional container
│   └── lib/
│       ├── common.sh
│       └── platform.sh
├── gui/
│   ├── Cargo.toml              # Phase 3: Tauri desktop
│   ├── tauri.conf.json
│   └── src/
└── ...
```

---

## Usage Examples

### CLI (Current)
```bash
sudo ./install.sh                    # Interactive
sudo ./install.sh -y                 # Non-interactive
sudo ./install.sh -m "system,pihole" # Specific modules
```

### TUI (Phase 1)
```bash
sudo ./install.sh --tui              # Terminal UI
sudo ./install.sh --tui -m "system"  # Pre-select modules
```

### Web UI (Phase 2)
```bash
sudo ./install.sh --gui              # Starts web server, prints URL
# Opens https://<ip>:8443 in browser
# Or manually: sudo ./scripts/gui/web_gui/run_gui.sh
```

### Desktop (Phase 3 - Future)
```bash
# Download .AppImage/.dmg/.msi
InitOps-gui                  # Native desktop app
```

---

## Quick Start for Development

```bash
# 1. Install TUI dependencies (already on Debian)
apt-get install whiptail dialog

# 2. Test TUI
./scripts/gui/tui_install.sh

# 3. For Web UI development
cd scripts/gui/web_gui
# Backend
cd backend && pip install -r requirements.txt && uvicorn main:app --reload --port 8443
# Frontend
cd ../frontend && npm install && npm run dev
```

---

## Decision Matrix

| Criteria | TUI (whiptail) | Web UI (FastAPI+React) | Desktop (Tauri) |
|----------|----------------|------------------------|-----------------|
| **SSH Friendly** | ✅ Native | ⚠️ Needs tunnel | ❌ No |
| **Headless Support** | ✅ Yes | ⚠️ Needs Xvfb | ❌ No |
| **Visual Polish** | ⚠️ Basic | ✅ Excellent | ✅ Excellent |
| **Mobile Friendly** | ❌ No | ✅ Yes | ❌ No |
| **Dev Effort** | Low (1 week) | Medium (3-4 weeks) | High (6+ weeks) |
| **Dependencies** | Minimal | Python + Node.js | Rust + WebView |
| **Security Surface** | Tiny | Medium | Medium |
| **Best For** | Quick start, servers | Production, remote mgmt | Power users |

---

## Recommendation

**Start with Phase 1 (TUI)** - Immediate value, works everywhere, minimal code.

**Then Phase 2 (Web UI)** - For production deployments where users want rich UI on phone/laptop.

**Skip Phase 3** unless there's strong demand - Web UI covers remote management better.

---

## Integration with install.sh

Add to argument parser:
```bash
--tui)     USE_TUI=true ;;
--gui)     USE_GUI=true ;;
```

Then in main():
```bash
if [[ "${USE_TUI}" == "true" ]]; then
    exec "${SCRIPT_DIR}/scripts/gui/tui_install.sh" "$@"
elif [[ "${USE_GUI}" == "true" ]]; then
    exec "${SCRIPT_DIR}/scripts/gui/web_gui/run_gui.sh" "$@"
fi
```