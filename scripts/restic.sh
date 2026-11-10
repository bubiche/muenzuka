#!/bin/bash
# restic with the box's settings, for manual use. Installed by Ansible (role
# backup) as /usr/local/sbin/homelab-restic. Run as root:
#   sudo homelab-restic critical snapshots
#   sudo homelab-restic documents ls latest
#   sudo homelab-restic critical restore latest --target /tmp/restore-test
set -euo pipefail
export RESTIC_PASSWORD_FILE=/etc/restic/password
export RCLONE_CONFIG=/etc/restic/rclone.conf
export RESTIC_CACHE_DIR=/var/cache/restic
export RESTIC_PACK_SIZE=64
case ${1:-} in
    critical|documents) repo=rclone:gdrive:homelab-$1; shift ;;
    *) echo "usage: homelab-restic critical|documents <restic command…>" >&2; exit 2 ;;
esac
exec restic -r "$repo" "$@"
