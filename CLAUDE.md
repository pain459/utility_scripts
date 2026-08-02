# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

A collection of cross-platform utility scripts for system maintenance and routine tasks. The codebase includes both POSIX-compliant shell/Python scripts for Linux/Unix and PowerShell scripts for Windows, organized by operating system.

## Project Structure

- **Linux/Unix**: Scripts for Ubuntu/Debian system maintenance (ppa-cleaner, install.sh)
- **Windows**: PowerShell scripts for Windows maintenance (in `windows_scripts/`)

## Common Commands

### Linux/Unix — ppa-cleaner

Detect and safely disable broken Ubuntu Launchpad PPAs:

- **Test active PPAs without changes**:
  ```bash
  sudo ppa-cleaner check
  ```

- **Preview what would be disabled**:
  ```bash
  sudo ppa-cleaner clean
  ```

- **Disable PPAs matching a policy**:
  ```bash
  sudo ppa-cleaner clean --apply --policy dead
  ```

- **Disable with broader failure detection**:
  ```bash
  sudo ppa-cleaner clean --apply --policy broken
  ```

- **Disable with all failure types (use cautiously)**:
  ```bash
  sudo ppa-cleaner clean --apply --policy all
  ```

- **Run with custom parameters**:
  ```bash
  sudo ppa-cleaner clean --apply --policy dead --attempts 3 --timeout 20 --jobs 4
  ```

- **Write machine-readable report**:
  ```bash
  sudo ppa-cleaner check --json-report /tmp/ppa-report.json
  ```

- **List backups**:
  ```bash
  sudo ppa-cleaner backups
  ```

- **Restore from backup**:
  ```bash
  sudo ppa-cleaner restore latest --apply
  ```

- **Enable weekly timer**:
  ```bash
  sudo systemctl enable --now ppa-cleaner.timer
  ```

### Linux/Unix — Installation

```bash
# Install ppa-cleaner
sudo chmod +x install.sh
sudo ./install.sh

# Install with automatic timer (runs weekly at 04:15 with ~30 min delay)
sudo ./install.sh --enable-timer
```

### Windows — Maintenance Scripts

- **Run full Windows maintenance** (disk cleanup, Windows Updates, SFC, temp cleanup):
  ```powershell
  # Run as Administrator
  powershell -ExecutionPolicy Bypass -File "windows_scripts\maintenance.ps1"
  ```

- **Update all Chocolatey packages**:
  ```powershell
  # Run as Administrator
  powershell -ExecutionPolicy Bypass -File "windows_scripts\update-choco-packages.ps1"
  ```

## Architecture & Big Picture

### ppa-cleaner (Linux)

A conservative, standard-library-only Python utility for detecting and disabling broken Ubuntu Launchpad PPAs.

**Key design principles:**
- Dry-run by default; changes require `--apply`
- Tests each PPA independently with `apt-get`
- Supports both classic `/etc/apt/sources.list` and deb822 `*.sources` formats
- Classifies failures into three policies:
  - **dead**: 404, 410, or missing Release files
  - **broken**: Everything in `dead` plus signature, key, auth, malformed entry, and Signed-By errors
  - **all**: Every failed result, including transient network errors
- Creates timestamped backups and a JSON manifest before editing
- Uses atomic file replacement to prevent corruption

**Command structure:**
```
ppa-cleaner [command] [options]

Commands:
  check      — Test matching active PPAs without changing files
  clean      — Test PPAs and optionally disable failures (default: --policy dead)
  backups    — List available cleanup backups
  restore    — Restore source files from a cleanup backup (e.g., restore latest)
```

**Backup and restore workflow:**
- Backups stored under `/var/backups/ppa-cleaner/<UTC timestamp>/`
- Each backup contains the original files + `manifest.json` with disabled entries
- `restore` command refuses to overwrite files changed since backup unless `--force` is specified

### Windows Maintenance

Two PowerShell scripts that run as Administrator:

1. **maintenance.ps1**: Full Windows maintenance
   - Disk cleanup (cleanmgr)
   - Windows Update check and install
   - Disk defragmentation (skips SSDs)
   - Clear temporary files
   - System File Checker (SFC)
   - Execution policy warning

2. **update-choco-packages.ps1**: Chocolatey upgrades
   - Checks and warns about restricted execution policy
   - Runs `choco upgrade all -y`

**Note**: Windows scripts require `PSWindowsUpdate` module for the update script. If missing:
```powershell
Install-Module PSWindowsUpdate -Force -Scope CurrentUser
```

## Cross-Platform Patterns

- **Dry-run first**: All destructive operations have a preview mode
- **Root/sudo required**: Scripts that modify system state require elevated privileges
- **Backups before changes**: Changes create timestamped backups with manifest
- **Parallel processing**: ppa-cleaner supports concurrent checks (`--jobs`)
- **Exit codes**: ppa-cleaner uses standardized exit codes (0=success, 1=failures found, 2=error, 130=interrupted)