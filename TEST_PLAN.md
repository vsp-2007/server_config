# Test & Fix Plan for Pi Server Setup v2 on Debian Test Server

## Target Server
- **IP**: 10.131.168.3
- **User**: nova
- **Password**: 123
- **OS**: Debian 13 (Trixie) - Linux 6.12.95+deb13-amd64

## Current State
- Repository cloned to `~/InitOps`
- install.sh exists but may need chmod +x
- settings.conf not yet created (needs copy from config/settings.conf.example)
- Git branch: v2-development

## Test Plan

### Phase 1: Basic Validation (No root needed)
1. `chmod +x install.sh`
2. `./install.sh --dry-run` - Should validate config, prompt for missing values
3. Check if settings.conf.example exists and is readable

### Phase 2: Config Creation
1. Copy `config/settings.conf.example` → `settings.conf`
2. `chmod 600 settings.conf`
3. Verify install.sh can load it

### Phase 3: Install Test (CLI Mode)
1. Run `sudo ./install.sh` (interactive)
2. Select mode: 1 (CLI - stable)
3. Should prompt for missing config values
4. Select minimal modules: system, network
4. Verify no raw ANSI codes, log dir creation works

### Phase 4: TUI Mode Test
1. `sudo ./install.sh --tui`
2. Should install dialog if missing
2. Test module selection, config form, progress gauge

### Phase 5: Fix Issues & Push
- Document any errors found
- Apply fixes locally
- Push to v2-development branch

## Commands to Run on Server

```bash
# 1. Setup
cd ~/InitOps
chmod +x install.sh
ls -la config/settings.conf.example

# 2. Dry run (no root needed for this)
./install.sh --dry-run

# 3. Create config
cp config/settings.conf.example settings.conf
chmod 600 settings.conf

# 4. Test with minimal install (will need sudo)
# sudo ./install.sh -m "system,network" -y  # Non-interactive test
# OR
# sudo ./install.sh  # Interactive mode selection
```

## Expected Issues to Fix
- [ ] Log directory creation timing
- [ ] ANSI code suppression under sudo
- [ ] Config file auto-creation
- [ ] TUI tool auto-install
- [ ] Config validation edge cases

## Git Workflow
- All fixes on v2-development branch
- No changes to main branch
- Push fixes after verification