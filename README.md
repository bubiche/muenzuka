# muenzuka

The configuration of a one-box homelab: a mini PC running Ubuntu Server, set up with Ansible, running its services in Docker Compose, and backed up nightly with restic.

This is the shareable part of a private repo, exported by a script. Personal values (names, addresses, tailnet, repo URL) live only in the private inventory, and the plans, runbook and logs stay private. Comments that mention `RUNBOOK.md` or `homelab_ideas.md` point to those private notes.

## What it does

- **Services (`compose.yml`):**
  - AdGuard Home: DNS and ad blocking for the LAN and the tailnet.
  - Vaultwarden: password manager.
  - ntfy: push notifications to a phone.
  - Samba (on the host, role `samba`): one file share.
  - Image versions are pinned exactly; Renovate opens update PRs.
- **Nothing is exposed to the internet:**
  - Every web UI listens on `127.0.0.1` only. `tailscale serve` publishes each one over HTTPS, on its own port, to the tailnet only.
  - ufw allows the LAN only DNS, game streaming (Sunshine) and SSH with a break-glass key (passwords are off). Everything else goes through Tailscale.
  - Samba accepts tailnet addresses only, in ufw and in `hosts allow`.
- **Backups (`scripts/backup.sh`, role `backup`):**
  - restic to Google Drive through rclone, nightly. Two repos: `critical` (the stack, with a safe SQLite dump of Vaultwarden first) and `documents` (the file share).
  - Retention, prune and check every Saturday. On the 1st of the month, `check --read-data-subset=2%`, then an automatic restore test of `critical`: restore to tmpfs with `--verify`, check the key files, and open the Vaultwarden dump.
  - The documents backup is skipped, with an alert, when Drive has under 2GB free.
  - Each repo pings its own healthchecks.io check with the exit code and the log tail.
- **Updates, without anyone logging in:**
  - unattended-upgrades for packages (including Docker and Tailscale), a weekly reboot window only when an update needs one, snaps refreshed on Sunday morning.
  - **Weekly self-update (`scripts/pull.sh`, role `pull`):** the box clones this config with a read-only deploy key (GitHub's host keys pinned) and runs the same playbook against itself. A merged Renovate PR reaches the box the next Sunday.
  - **Weekly report (`scripts/report.py`, role `report`):** one push via the box's own ntfy, with pending updates, failed units, container health, disk and SSD wear (smartctl), Drive quota, backup age and the last restore test. Warnings make it high priority.
- **Headless:** the display connector is forced on with no monitor attached, so game streaming (Sunshine) still works.

## Layout

| Path | What it is |
|---|---|
| `ansible/site.yml` | The playbook: roles `base`, `backup`, `docker`, `tailscale`, `samba`, `pull`, `report`, in that order |
| `ansible/roles/` | One folder per role: `defaults/` (settings), `tasks/`, `handlers/`, `templates/` |
| `ansible/inventory.example.yml` | Template for the private `inventory.yml`: the host and every personal value |
| `ansible/vault.example.yml` | Template for `group_vars/all/vault.yml` (Ansible Vault): healthchecks URLs, restic password |
| `compose.yml` | The Docker stack; the box's Tailscale name comes from `/opt/homelab/.env`, written by Ansible |
| `scripts/` | Installed on the box by the roles: `homelab-backup`, `homelab-restic`, `homelab-pull`, `homelab-report` |
| `renovate.json` | Update PRs for the compose images and the pinned rclone `.deb`; patch and minor updates merge themselves after 3 days |
| `.githooks/pre-commit` | gitleaks on every commit |

## Using it yourself

It is written for one specific box, so read it as an example rather than a turnkey install. To adapt it:

1. Ubuntu Server (26.04 here) on the box, joined to your tailnet with Tailscale SSH on. Some steps stay manual: Tailscale itself, Sunshine, Samba passwords (`smbpasswd -a`), and the rclone Google Drive remote.
2. `cp ansible/inventory.example.yml ansible/inventory.yml` and fill it in.
3. `ansible-vault create ansible/group_vars/all/vault.yml` with the keys from `vault.example.yml`.
4. Put your break-glass SSH public key in `ansible/roles/base/files/breakglass.pub`.
5. Install the collections: `ansible-galaxy collection install community.general community.docker ansible.posix`.
6. From `ansible/`: `ansible-playbook site.yml --check --diff`, then `ansible-playbook site.yml`. It asks for the sudo password on purpose.
7. Before turning on the weekly pull, add the deploy key the `pull` role prints to your repo (read-only).

Turn on the commit hook once per clone: `git config core.hooksPath .githooks` (needs `gitleaks`).
