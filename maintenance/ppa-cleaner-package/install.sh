#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENABLE_TIMER=false

usage() {
  cat <<'USAGE'
Usage: sudo ./install.sh [--enable-timer]

Installs:
  /usr/local/sbin/ppa-cleaner
  /usr/local/share/doc/ppa-cleaner/README.md
  /etc/systemd/system/ppa-cleaner.service
  /etc/systemd/system/ppa-cleaner.timer
USAGE
}

while (($#)); do
  case "$1" in
    --enable-timer) ENABLE_TIMER=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Run this installer with sudo." >&2
  exit 2
fi

install -Dm755 "$SCRIPT_DIR/ppa-cleaner.py" /usr/local/sbin/ppa-cleaner
install -Dm644 "$SCRIPT_DIR/README.md" /usr/local/share/doc/ppa-cleaner/README.md
install -Dm644 "$SCRIPT_DIR/ppa-cleaner.service" /etc/systemd/system/ppa-cleaner.service
install -Dm644 "$SCRIPT_DIR/ppa-cleaner.timer" /etc/systemd/system/ppa-cleaner.timer
systemctl daemon-reload

if [[ "$ENABLE_TIMER" == true ]]; then
  systemctl enable --now ppa-cleaner.timer
  echo "Installed and enabled ppa-cleaner.timer."
else
  echo "Installed. The timer was not enabled."
  echo "Preview first: sudo ppa-cleaner clean"
  echo "Enable later: sudo systemctl enable --now ppa-cleaner.timer"
fi
