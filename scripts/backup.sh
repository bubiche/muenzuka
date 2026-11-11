#!/bin/bash
# shellcheck disable=SC2329,SC2181  # job_* are called as "job_$name"; $? is checked on purpose (see the loop)
# Nightly backup to Google Drive. Installed by Ansible (role backup) as
# /usr/local/sbin/homelab-backup and run by homelab-backup.timer at 02:00.
#
#   1. critical:  Vaultwarden dump, Immich database dump, then restic backup of
#                 /opt/homelab (a failed Immich dump still backs up the rest,
#                 then fails the run)
#   2. documents: restic backup of /srv/files/documents, skipped (and alerted)
#                 when Drive has under 2GB free
#
# Each repo also gets, in the same run (so nothing overlaps a backup):
#   - Saturdays: forget --prune with the retention policy, then check
#   - the 1st of the month: check --read-data-subset=2%
# and critical, on the 1st of the month: a restore test (job_restore_test).
# Each repo pings its own healthchecks.io check: /start, then the exit code with
# the tail of the log, so a failed prune or check also alerts.
#
# Usage (as root): homelab-backup [critical] [documents] [restore-test]
#   (default: critical documents; restore-test runs the restore test now)
set -uo pipefail

export RESTIC_PASSWORD_FILE=/etc/restic/password
export RCLONE_CONFIG=/etc/restic/rclone.conf
export RESTIC_CACHE_DIR=/var/cache/restic
export RESTIC_PACK_SIZE=64          # MiB: fewer files, for Drive's rate limit
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

REPO_CRITICAL=rclone:gdrive:homelab-critical
REPO_DOCUMENTS=rclone:gdrive:homelab-documents
STACK=/opt/homelab
VW_DATA=$STACK/vaultwarden/data
IMMICH_DUMPS=$STACK/immich/dumps   # the photo library (/srv/immich) is never backed up
DOCUMENTS=/srv/files/documents
RESTORE_STATE=/var/lib/homelab/restore-test   # read by the weekly report
MIN_FREE_BYTES=$((2 * 1024 * 1024 * 1024))
KEEP=(--keep-hourly 24 --keep-daily 30 --keep-monthly 12)

# Ping URLs (HC_BACKUP_CRITICAL, HC_BACKUP_DOCUMENTS). Secret: never echo them.
# shellcheck source=/dev/null
. /etc/homelab/healthchecks.env

exec 9>/run/homelab-backup.lock
if ! flock -n 9; then
    echo "Another backup is running; exiting." >&2
    exit 1
fi

# hc <url> <suffix> [file]: ping healthchecks.io, with the file's tail as the body.
hc() {
    local url=$1 suffix=$2 file=${3:-}
    [ -n "$url" ] || return 0
    if [ -n "$file" ]; then
        tail -c 20000 "$file" | curl -fsS -m 10 --retry 5 -o /dev/null --data-binary @- "$url$suffix" || true
    else
        curl -fsS -m 10 --retry 5 -o /dev/null "$url$suffix" || true
    fi
}

# maintenance <repo>: weekly prune + check, monthly partial read of the data.
maintenance() {
    local repo=$1
    if [ "$(date +%u)" = 6 ]; then
        echo "== Saturday: forget --prune, then check"
        restic -r "$repo" forget --group-by host,tags "${KEEP[@]}" --prune
        restic -r "$repo" check
    fi
    if [ "$(date +%d)" = 01 ]; then
        echo "== 1st of the month: check --read-data-subset=2%"
        restic -r "$repo" check --read-data-subset=2%
    fi
}

# dump_immich: Immich's database, dumped the way Immich dumps it itself
# (pg_dump --clean --if-exists | gzip --rsyncable, so restic can dedup the
# unchanged parts) and named like Immich's own backups, so its restore page
# accepts it (RUNBOOK → Immich). Keeps 7 days. Explicit returns, not set -e:
# it's called after ||, because a failed dump must not stop the vault's upload.
dump_immich() {
    local version pg out
    version=$(docker inspect -f '{{.Config.Image}}' immich_server) || return 1
    version=${version##*:}
    pg=$(docker exec immich_postgres psql --username=postgres -tAc 'show server_version') || return 1
    pg=${pg%% *}
    out="$IMMICH_DUMPS/immich-db-backup-$(date +%Y%m%dT%H%M%S)-$version-pg$pg.sql.gz"
    rm -f "$IMMICH_DUMPS"/*.tmp
    docker exec immich_postgres pg_dump --clean --if-exists --dbname=immich --username=postgres \
        | gzip --rsyncable > "$out.tmp" || { rm -f "$out.tmp"; return 1; }
    mv "$out.tmp" "$out" || return 1
    echo "Wrote ${out##*/} ($(du -h "$out" | cut -f1))"
    # Rotation is housekeeping: a failure here must not mark a good dump as failed.
    find "$IMMICH_DUMPS" -maxdepth 1 -name 'immich-db-backup-*.sql.gz' -mtime +6 -print -delete \
        || echo "Warning: could not delete old Immich dumps"
    return 0
}

# Each job runs in a subshell with set -e: the first failing command ends it.
job_critical() (
    set -e
    echo "== Vaultwarden: safe SQLite dump"
    docker exec vaultwarden /vaultwarden backup
    find "$VW_DATA" -maxdepth 1 -name 'db_*.sqlite3' -mtime +6 -print -delete
    echo "== Immich: database dump"
    immich_rc=0
    dump_immich || immich_rc=$?
    echo "== restic backup -> $REPO_CRITICAL"
    restic -r "$REPO_CRITICAL" backup --tag critical --exclude-caches \
        --exclude "$VW_DATA/db.sqlite3" \
        --exclude "$VW_DATA/db.sqlite3-wal" \
        --exclude "$VW_DATA/db.sqlite3-shm" \
        --exclude "$VW_DATA/icon_cache" \
        --exclude "$VW_DATA/tmp" \
        --exclude "$STACK/adguard/work" \
        --exclude "$STACK/ntfy" \
        --exclude "$STACK/immich/postgres*" \
        "$STACK"
    maintenance "$REPO_CRITICAL"
    if [ "$(date +%d)" = 01 ]; then
        job_restore_test
    fi
    if [ "$immich_rc" -ne 0 ]; then
        echo "FAILED: the Immich database dump (exit $immich_rc). Everything else was backed up."
        exit 1
    fi
)

# Restore the latest critical snapshot into a throwaway dir (tmpfs: the
# secrets in it never touch the disk), verify every file against the
# snapshot, check that the Vaultwarden dump opens and holds the vault, and
# that the newest Immich dump is a whole gzip file of a complete pg_dump.
# The result goes to $RESTORE_STATE for the weekly report. This proves the
# backup is readable; the yearly drill from the Mac proves the break-glass
# sheet is enough (RUNBOOK: Restore drill).
job_restore_test() (
    set -e
    step="start" detail=""
    dir=$(mktemp -d /tmp/homelab-restore-test.XXXXXX)
    # shellcheck disable=SC2154  # rc is set inside the trap
    trap 'rc=$?; rm -rf "$dir"
          install -d -m 0700 "${RESTORE_STATE%/*}"
          printf "date=%s\nresult=%s\ndetail=%s\n" "$(date -Is)" \
              "$([ $rc -eq 0 ] && echo ok || echo "failed at: $step")" "$detail" > "$RESTORE_STATE"' EXIT
    echo "== Restore test: latest critical snapshot -> $dir"
    step="find the latest snapshot"
    snap=$(restic -r "$REPO_CRITICAL" snapshots --latest 1 --json \
        | python3 -I -c 'import json,sys; print(json.load(sys.stdin)[-1]["short_id"])')
    detail="snapshot $snap"
    step="restore --verify"
    restic -r "$REPO_CRITICAL" restore "$snap" --target "$dir" --verify
    step="expected files"
    for f in "$STACK/compose.yml" "$STACK/adguard/conf/AdGuardHome.yaml" "$VW_DATA/rsa_key.pem"; do
        [ -s "$dir$f" ] || { echo "Missing or empty: $f"; false; }
    done
    step="Vaultwarden dump"
    dump=$(find "$dir$VW_DATA" -maxdepth 1 -name 'db_*.sqlite3' | sort | tail -n 1)
    [ -n "$dump" ] || { echo "No db_*.sqlite3 dump in the snapshot"; false; }
    counts=$(python3 -I - "$dump" <<'PY'
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
ok = db.execute("pragma integrity_check").fetchone()[0]
users = db.execute("select count(*) from users").fetchone()[0]
items = db.execute("select count(*) from ciphers").fetchone()[0]
print(f"integrity_check {ok}, {users} user(s), {items} item(s)")
sys.exit(0 if ok == "ok" and users >= 1 and items >= 1 else 1)
PY
    ) || { detail="snapshot $snap, ${dump##*/}, $counts (needs integrity_check ok, at least 1 user and 1 item)"; echo "$detail"; false; }
    detail="snapshot $snap, ${dump##*/}, $counts"
    step="Immich dump"
    idump=$(find "$dir$IMMICH_DUMPS" -maxdepth 1 -name 'immich-db-backup-*.sql.gz' | sort | tail -n 1)
    [ -n "$idump" ] || { echo "No immich-db-backup-*.sql.gz dump in the snapshot"; false; }
    gzip -t "$idump"
    # pg_dump writes this line last: without it the dump was cut short.
    gzip -dc "$idump" | tail -n 5 | grep -q 'PostgreSQL database dump complete' \
        || { echo "Immich dump is incomplete (no 'dump complete' line): ${idump##*/}"; false; }
    detail="$detail, ${idump##*/}"
    echo "Restore test passed: $detail"
)

job_documents() (
    set -e
    echo "== Drive free space"
    free=$(rclone about gdrive: --json | python3 -c 'import json,sys; print(json.load(sys.stdin)["free"])')
    echo "Free: $((free / 1024 / 1024)) MiB"
    if [ "$free" -lt "$MIN_FREE_BYTES" ]; then
        echo "SKIPPED: under 2GB free on Drive. critical still runs; free up space or upgrade storage."
        exit 1
    fi
    echo "== restic backup -> $REPO_DOCUMENTS"
    restic -r "$REPO_DOCUMENTS" backup --tag documents --exclude-caches \
        --exclude "$DOCUMENTS/.recycle" \
        "$DOCUMENTS"
    maintenance "$REPO_DOCUMENTS"
)

# run <name> <ping-url>: run job_<name>, log to the journal and to healthchecks.io.
run() {
    local name=$1 url=$2 log rc
    log=$(mktemp)
    hc "$url" /start
    echo "### $name: start $(date -Is)"
    "job_$name" 2>&1 | tee "$log"
    rc=${PIPESTATUS[0]}
    echo "### $name: exit $rc $(date -Is)"
    hc "$url" "/$rc" "$log"
    rm -f "$log"
    return "$rc"
}

jobs=("$@")
[ "${#jobs[@]}" -gt 0 ] || jobs=(critical documents)

# Don't call `run` after || or &&, or inside `if`: bash would then ignore the
# job's set -e and carry on after a failed command.
status=0
for job in "${jobs[@]}"; do
    case $job in
        critical)  run critical "${HC_BACKUP_CRITICAL:-}" ;;
        documents) run documents "${HC_BACKUP_DOCUMENTS:-}" ;;
        restore-test) run restore_test "${HC_BACKUP_CRITICAL:-}" ;;
        *) echo "Unknown job: $job" >&2; false ;;
    esac
    [ $? -eq 0 ] || status=1
done
exit "$status"
