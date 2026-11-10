#!/usr/bin/python3 -I
"""Weekly report for the box, sent as a push through the box's own ntfy.

Installed by Ansible (role report) as /usr/local/sbin/homelab-report and run by
homelab-report.timer (Sunday 06:00, after the 05:00 pull). Runs as root.

  homelab-report           build the report and send it to ntfy
  homelab-report --print   build it and print it, send nothing

Each section is independent: one that fails says so (and raises a warning)
instead of stopping the report. Warnings go first and make the push high
priority. Thresholds are below.
"""
import datetime as dt
import glob
import gzip
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.request

NTFY_ENV = "/etc/homelab/ntfy.env"          # NTFY_URL=http://127.0.0.1:2586/<topic> (self-hosted ntfy)
SSD = "/dev/nvme0n1"
DISK_WARN_PCT = 80
DRIVE_WARN_PCT = 80                          # of the Google account's whole quota
SSD_WEAR_WARN_PCT = 80
BACKUP_MAX_AGE_H = 48
REPOS = ("critical", "documents")
RESTORE_STATE = "/var/lib/homelab/restore-test"  # written by homelab-backup's restore test
RESTORE_MAX_AGE_D = 35                            # monthly, on the 1st
MAX_BODY = 3800                              # ntfy turns longer messages into attachments

os.environ["PATH"] = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
warns: list[str] = []
lines: list[str] = []
SECTIONS = []


def run(*cmd: str, timeout: int = 300) -> str:
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout


def gib(n: float) -> str:
    return f"{n / 1024**3:.1f}G"


def section(name):
    """Register a report section; main() runs them in order."""
    def wrap(fn):
        SECTIONS.append((name, fn))
        return fn
    return wrap


@section("System")
def system():
    up = float(open("/proc/uptime").read().split()[0])
    lines.append(f"Up {int(up // 86400)}d {int(up % 86400 // 3600)}h, kernel {os.uname().release}")
    if os.path.exists("/run/reboot-required"):
        pkgs = open("/run/reboot-required.pkgs").read().split() if os.path.exists("/run/reboot-required.pkgs") else []
        lines.append(f"Reboot pending ({', '.join(pkgs) or 'no package list'}); the Sunday 04:00 window should take it")
    else:
        lines.append("No reboot pending")


@section("Updates")
def updates():
    since = dt.datetime.now() - dt.timedelta(days=7)
    names: set[str] = set()
    for path in sorted(glob.glob("/var/log/apt/history.log*")):
        opener = gzip.open if path.endswith(".gz") else open
        with opener(path, "rt", errors="replace") as f:
            for block in f.read().split("\n\n"):
                m = re.search(r"^Start-Date: (\S+)\s+(\S+)", block, re.M)
                if not m or dt.datetime.fromisoformat(f"{m[1]}T{m[2]}") < since:
                    continue
                for line in re.findall(r"^(?:Upgrade|Install): (.*)$", block, re.M):
                    names.update(re.findall(r"([^\s,()]+?):[a-z0-9]+ \(", line))
    shown = ", ".join(sorted(names)[:12]) + (" …" if len(names) > 12 else "")
    lines.append(f"Updated in 7 days: {len(names)} package(s)" + (f": {shown}" if names else ""))
    waiting = [l for l in run("apt", "list", "--upgradable").splitlines() if "/" in l]
    lines.append(f"Waiting (not automatic): {len(waiting)} package(s)")


@section("Services")
def services():
    failed = run("systemctl", "--failed", "--no-legend", "--plain").split("\n")
    failed = [l.split()[0] for l in failed if l.strip()]
    if failed:
        warns.append(f"failed units: {', '.join(failed)}")
    lines.append(f"Failed units: {', '.join(failed) or 'none'}")
    # systemd only remembers runs since the last boot.
    for unit, label in (("homelab-backup.service", "Last backup run"), ("homelab-pull.service", "Last pull run")):
        p = dict(l.split("=", 1) for l in run("systemctl", "show", unit, "-p", "Result",
                                                "-p", "ExecMainExitTimestamp").splitlines() if "=" in l)
        if not p.get("ExecMainExitTimestamp"):
            lines.append(f"{label}: not run since boot")
            continue
        lines.append(f"{label}: {p.get('Result', '?')} ({p['ExecMainExitTimestamp']})")
        if p.get("Result") != "success":
            warns.append(f"{label.lower()}: {p.get('Result')}")
    clone = "/var/lib/homelab/repo"
    if os.path.isdir(f"{clone}/.git"):
        fetched = dt.datetime.fromtimestamp(os.path.getmtime(f"{clone}/.git/FETCH_HEAD")) \
            if os.path.exists(f"{clone}/.git/FETCH_HEAD") else None
        commit = run("git", "-C", clone, "log", "-1", "--format=%h %s").strip()
        lines.append(f"Applied commit: {commit}" + (f" (fetched {fetched:%a %d %b %H:%M})" if fetched else ""))


@section("Containers")
def containers():
    rows = [json.loads(l) for l in run("docker", "ps", "-a", "--format", "{{json .}}").splitlines() if l]
    bad = [r["Names"] for r in rows if r["State"] != "running" or "unhealthy" in r["Status"]]
    if bad:
        warns.append(f"containers not healthy: {', '.join(bad)}")
    lines.append("Containers: " + ", ".join(f"{r['Names']} {r['Status']}" for r in rows))


@section("Disk")
def disk():
    u = shutil.disk_usage("/")
    pct = u.used * 100 // u.total
    if pct >= DISK_WARN_PCT:
        warns.append(f"disk {pct}% full")
    lines.append(f"Disk /: {pct}% ({gib(u.used)} of {gib(u.total)})")


@section("SSD")
def ssd():
    d = json.loads(run("smartctl", "-a", "-j", SSD))
    h = d["nvme_smart_health_information_log"]
    ok = d.get("smart_status", {}).get("passed")
    if not ok or h["critical_warning"] or h["media_errors"] \
            or h["percentage_used"] >= SSD_WEAR_WARN_PCT or h["available_spare"] <= h["available_spare_threshold"]:
        warns.append("SSD health needs a look")
    lines.append(f"SSD: {'PASSED' if ok else 'FAILED'}, wear {h['percentage_used']}%, "
                 f"spare {h['available_spare']}%, media errors {h['media_errors']}, "
                 f"{h['temperature']}°C, {h['power_on_hours']}h on")


@section("Drive")
def drive():
    env = dict(os.environ, RCLONE_CONFIG="/etc/restic/rclone.conf")
    a = json.loads(subprocess.run(["rclone", "about", "gdrive:", "--json"], capture_output=True,
                                  text=True, timeout=120, env=env).stdout)
    # With scope drive.file, "used" is only rclone's own files; Gmail and Photos
    # are under "other". The whole account is total - free.
    used = a["total"] - a["free"]
    pct = used * 100 // a["total"]
    if pct >= DRIVE_WARN_PCT:
        warns.append(f"Google storage {pct}% full: time for Google One 100GB or B2")
    lines.append(f"Google storage: {pct}% ({gib(used)} of {gib(a['total'])}; backups {gib(a['used'])}, "
                 f"{gib(a['free'])} free)")


@section("Backups")
def backups():
    now = dt.datetime.now(dt.timezone.utc)
    for repo in REPOS:
        snaps = json.loads(run("homelab-restic", repo, "snapshots", "--latest", "1", "--json") or "[]")
        if not snaps:
            warns.append(f"no {repo} snapshot")
            lines.append(f"Backup {repo}: no snapshots")
            continue
        # restic prints nanoseconds; keep microseconds for fromisoformat.
        t = dt.datetime.fromisoformat(re.sub(r"(\.\d{6})\d+", r"\1", snaps[-1]["time"]))
        age_h = (now - t).total_seconds() / 3600
        if age_h > BACKUP_MAX_AGE_H:
            warns.append(f"{repo} backup is {age_h:.0f}h old")
        lines.append(f"Backup {repo}: {snaps[-1]['short_id']}, {age_h:.0f}h ago")


@section("Restore test")
def restore_test():
    if not os.path.exists(RESTORE_STATE):
        warns.append("no restore test recorded")
        lines.append("Restore test: none recorded (run: sudo homelab-backup restore-test)")
        return
    st = dict(l.split("=", 1) for l in open(RESTORE_STATE).read().splitlines() if "=" in l)
    when = dt.datetime.fromisoformat(st["date"])
    age_d = (dt.datetime.now(dt.timezone.utc) - when).days
    if st.get("result") != "ok":
        warns.append(f"restore test {st.get('result')}")
    elif age_d > RESTORE_MAX_AGE_D:
        warns.append(f"restore test is {age_d} days old")
    lines.append(f"Restore test: {st.get('result')} {when:%a %d %b} ({st.get('detail') or 'no detail'})")


def main() -> int:
    for name, fn in SECTIONS:
        try:
            fn()
        except Exception as e:  # one broken section must not stop the report
            lines.append(f"{name}: error ({type(e).__name__}: {e})")
            warns.append(f"{name} check failed")
    body = "\n".join(([f"⚠ {w}" for w in warns] + [""] if warns else []) + lines)[:MAX_BODY]
    host = os.uname().nodename
    title = f"{host} weekly: {len(warns)} warning(s)" if warns else f"{host} weekly: all good"
    if "--print" in sys.argv:
        print(title, body, sep="\n\n")
        return 0
    url = next(l.split("=", 1)[1].strip() for l in open(NTFY_ENV) if l.startswith("NTFY_URL="))
    req = urllib.request.Request(url, data=body.encode(), method="POST", headers={
        "Title": title,
        "Priority": "high" if warns else "default",
        "Tags": "warning" if warns else "white_check_mark",
    })
    urllib.request.urlopen(req, timeout=30).read()
    print(f"Sent: {title}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
