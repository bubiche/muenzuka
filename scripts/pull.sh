#!/bin/bash
# shellcheck disable=SC2181  # $? is checked on purpose (see the end)
# Weekly self-update: the box applies the repo's main branch to itself.
# Installed by Ansible (role pull) as /usr/local/sbin/homelab-pull and run by
# homelab-pull.timer (Sunday 05:00). The same thing ansible-pull does, written
# out so the settings are explicit:
#   1. update a clone of the repo (read-only deploy key, GitHub's pinned host keys)
#   2. ansible-playbook site.yml against this box, locally, as root
# Pings HC_ANSIBLE_PULL: /start, then the exit code with the tail of the log.
#
# Usage (as root): homelab-pull
set -uo pipefail

# REPO_URL (the private repo's SSH URL), written by the pull role from the inventory.
# shellcheck source=/dev/null
. /etc/homelab/pull.env
: "${REPO_URL:?REPO_URL missing from /etc/homelab/pull.env (apply the pull role)}"
BRANCH=main
DIR=/var/lib/homelab/repo

export HOME=/root
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export GIT_SSH_COMMAND="ssh -i /etc/homelab/deploy_key -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o BatchMode=yes"
# Run from the clone's root, so the Mac's ansible/ansible.cfg (sudo password
# prompt, Mac vault path) is NOT loaded. These replace the settings needed here.
export ANSIBLE_VAULT_PASSWORD_FILE=/etc/homelab/vault-pass
export ANSIBLE_INTERPRETER_PYTHON=auto_silent
export ANSIBLE_RETRY_FILES_ENABLED=False
export ANSIBLE_NOCOLOR=1

# Ping URLs. Secret: never echo them.
# shellcheck source=/dev/null
. /etc/homelab/healthchecks.env

exec 9>/run/homelab-pull.lock
if ! flock -n 9; then
    echo "Another pull is running; exiting." >&2
    exit 1
fi

hc() {
    local suffix=$1 file=${2:-}
    [ -n "${HC_ANSIBLE_PULL:-}" ] || return 0
    if [ -n "$file" ]; then
        tail -c 20000 "$file" | curl -fsS -m 10 --retry 5 -o /dev/null --data-binary @- "$HC_ANSIBLE_PULL$suffix" || true
    else
        curl -fsS -m 10 --retry 5 -o /dev/null "$HC_ANSIBLE_PULL$suffix" || true
    fi
}

job() (
    set -e
    echo "== git: $REPO_URL ($BRANCH) -> $DIR"
    if [ -d "$DIR/.git" ]; then
        git -C "$DIR" fetch --quiet origin "$BRANCH"
        git -C "$DIR" reset --hard --quiet FETCH_HEAD
        git -C "$DIR" clean -fdxq
    else
        git clone --quiet --branch "$BRANCH" "$REPO_URL" "$DIR"
    fi
    echo "== commit: $(git -C "$DIR" log -1 --format='%h %ci %s')"
    cd "$DIR"
    echo "== ansible-playbook (local, as root)"
    ansible-playbook ansible/site.yml -i ansible/inventory.yml -l safehouse -c local
)

log=$(mktemp)
hc /start
echo "### pull: start $(date -Is)"
# Not after || or &&: bash would ignore the job's set -e.
job 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}
echo "### pull: exit $rc $(date -Is)"
hc "/$rc" "$log"
rm -f "$log"
exit "$rc"
