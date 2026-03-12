#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="/usr/local/sbin/mellanox-temp-monitor.sh"
TARGET_ENV="/etc/default/mellanox-temp-monitor"
TARGET_UNIT="/etc/systemd/system/mellanox-temp-monitor.service"

install -m 0755 "${SCRIPT_DIR}/mellanox-temp-monitor.sh" "$TARGET_SCRIPT"
install -m 0644 "${SCRIPT_DIR}/mellanox-temp-monitor.service" "$TARGET_UNIT"

if [[ -e "$TARGET_ENV" ]]; then
    install -m 0644 "${SCRIPT_DIR}/mellanox-temp-monitor.env" "${TARGET_ENV}.new"
    printf 'Existing %s preserved. Review %s.new for new defaults.\n' "$TARGET_ENV" "$TARGET_ENV"
else
    install -m 0644 "${SCRIPT_DIR}/mellanox-temp-monitor.env" "$TARGET_ENV"
fi

systemctl daemon-reload
systemctl enable --now mellanox-temp-monitor.service

printf 'Installed Mellanox temperature monitor.\n'
printf 'Config: %s\n' "$TARGET_ENV"
printf 'Service: systemctl status mellanox-temp-monitor.service\n'
printf 'Logs: journalctl -u mellanox-temp-monitor.service -f\n'
