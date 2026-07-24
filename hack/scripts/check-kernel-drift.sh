#!/usr/bin/env bash
# check-kernel-drift.sh - inspect kernel + unattended-upgrades state across nodes
set -uo pipefail

NODES=(
  k3s-cp-01:10.0.10.50
  k3s-cp-02:10.0.10.51
  k3s-cp-03:10.0.10.52
  k3s-wk-01:10.0.10.60
  k3s-wk-02:10.0.10.61
  k3s-wk-03:10.0.10.62
)
SSH_USER="k3s"

for entry in "${NODES[@]}"; do
  name="${entry%%:*}"
  ip="${entry##*:}"
  echo "================================================================"
  echo "### ${name} (${ip})"
  echo "================================================================"
  ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "${SSH_USER}@${ip}" bash -s <<'REMOTE'
    echo "--- running kernel ---"
    uname -r

    echo "--- latest installed kernel ---"
    ls -1 /boot/vmlinuz-* 2>/dev/null | sed 's|.*/vmlinuz-||' | sort -V | tail -1

    echo "--- reboot required? ---"
    if [ -f /var/run/reboot-required ]; then
      echo "YES"; cat /var/run/reboot-required.pkgs 2>/dev/null
    else
      echo "no"
    fi

    echo "--- unattended-upgrades installed/enabled ---"
    dpkg -l unattended-upgrades 2>/dev/null | awk '/^ii/{print "installed: "$3}'
    systemctl is-enabled unattended-upgrades.service 2>/dev/null || echo "service: not-enabled"
    systemctl is-enabled apt-daily-upgrade.timer 2>/dev/null || echo "timer: not-enabled"

    echo "--- APT auto-upgrade config (20auto-upgrades) ---"
    cat /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null || echo "(absent)"

    echo "--- Unattended-Upgrade origins / blacklist ---"
    grep -E 'Allowed-Origins|Origins-Pattern|Package-Blacklist|Automatic-Reboot' \
      /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null \
      | grep -vE '^\s*//' || echo "(none active)"

    echo "--- last unattended-upgrades activity ---"
    grep -h 'Packages that will be upgraded' /var/log/unattended-upgrades/unattended-upgrades.log 2>/dev/null | tail -3 || echo "(no log)"
    ls -1t /var/log/unattended-upgrades/ 2>/dev/null | head -3

    echo "--- held kernel packages ---"
    apt-mark showhold 2>/dev/null | grep -i linux || echo "(no holds)"
    echo
REMOTE
done
