#!/usr/bin/env bash
# Hookscript for the GitLab lab VM on pve2. The host has no swap and runs
# k3s-cp-02 and k3s-wk-02 with ballooning off, so this VM yields memory first.
set -euo pipefail

vmid="$1"
phase="$2"

case "$phase" in
  pre-start)
    # MemAvailable excludes the ZFS ARC, so this also refuses starts that rely on the ARC shrinking.
    # The 2048 MiB margin is a working threshold, not a measured limit.
    mem_mib=$(awk '/^memory:/ {print $2; exit}' "/etc/pve/qemu-server/${vmid}.conf")
    need_mib=$((mem_mib + 2048))
    avail_mib=$(( $(awk '/^MemAvailable:/ {print $2}' /proc/meminfo) / 1024 ))
    if (( avail_mib < need_mib )); then
      echo "not starting ${vmid}: MemAvailable ${avail_mib} MiB, need ${need_mib} MiB" >&2
      exit 1
    fi
    ;;
  post-start)
    # The host OOM killer takes this VM before any K3s VM; a snapshot rollback restores it.
    echo 1000 > "/proc/$(cat "/run/qemu-server/${vmid}.pid")/oom_score_adj"
    ;;
esac
