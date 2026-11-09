#!/usr/bin/env bash
# shellcheck shell=bash
# triage-bundle.sh — read-only evidence capture for Linux troubleshooting.
# Writes one tar.gz under $OUTDIR. No state changes: no writes outside OUTDIR,
# no service restarts, no kernel tracing. Safe on production.
#
#   ./triage-bundle.sh [outfile.tar.gz]
#
# Run it BEFORE changing anything, and again after a change to compare.
set -Eeuo pipefail
IFS=$'\n\t'

OUT="${1:-/var/tmp/triage.$(hostname 2>/dev/null || echo host).$(date -u +%Y%m%dT%H%M%SZ).txt}"
case "$OUT" in
  *.tar.gz) DIR="$(dirname -- "$OUT")"; TXT="${OUT%.tar.gz}.txt" ;;
  *)        DIR="$(dirname -- "$OUT")"; TXT="$OUT" ;;
esac
umask 077
mkdir -p -- "$DIR"
: >"$TXT"

have() { command -v "$1" >/dev/null 2>&1; }
run() { # run <label> <cmd...>  — never abort the bundle for one failing probe
  local label="$1"; shift  # SC2016 below is intentional: \$ expansions are deferred to the probe shell
  printf '\n===== %s =====\n$ %s\n' "$label" "$*" >>"$TXT"
  if have "$1"; then
    timeout 30 "$@" >>"$TXT" 2>&1 || printf '[exit %s]\n' "$?" >>"$TXT"
  else
    printf '[absent: %s]\n' "$1" >>"$TXT"
  fi
}

{
  printf 'triage bundle  UTC=%s  host=%s\n' "$(date -u +%FT%TZ)" "$(hostname 2>/dev/null || echo '?')"
  printf 'NOTE: read-only capture. Values are instantaneous unless sampled.\n'
} >>"$TXT"

# Identity, versions, clocks — the questions everything else depends on.
run os          bash -c 'cat /etc/os-release 2>/dev/null; uname -a'
run kernel      bash -c 'uname -r; cat /proc/cmdline'
run arch        bash -c 'getconf LONG_BIT; nproc; lscpu 2>/dev/null | head -25'
run clock       bash -c 'date -u; timedatectl status 2>/dev/null | head -20'
run cgroup      bash -c 'stat -fc %T /sys/fs/cgroup 2>/dev/null; ls /sys/fs/cgroup 2>/dev/null | head'
run mac         bash -c 'getenforce 2>/dev/null; sestatus 2>/dev/null | head -5; aa-status 2>/dev/null | head -5'

# What the machine already blames.
run failed      bash -c 'systemctl --failed --no-legend 2>/dev/null; systemctl is-system-running 2>/dev/null'
run journal-err bash -c 'journalctl -p err -b --no-pager 2>/dev/null | tail -n 60'
run journal-k   bash -c 'journalctl -k -b --no-pager 2>/dev/null | tail -n 80'
run dmesg       bash -c 'dmesg -T --level=err,warn 2>/dev/null | tail -n 60'
run prev-boot   bash -c 'journalctl -b -1 -p warning --no-pager 2>/dev/null | tail -n 40'

# Resources: utilization, saturation, errors (USE).
run uptime      bash -c 'uptime; cat /proc/loadavg; cat /proc/pressure/cpu /proc/pressure/memory /proc/pressure/io 2>/dev/null'
run vmstat      bash -c 'vmstat 1 5'
run mpstat      bash -c 'mpstat -P ALL 1 3'
run pidstat     bash -c 'pidstat 1 5 2>/dev/null | tail -n 30'
run iostat      bash -c 'iostat -xz 2 3'
run mem         bash -c 'free -h; grep -E "MemAvailable|CommitLimit|Committed_AS|Dirty|Writeback|SwapTotal|SwapFree|Slab" /proc/meminfo'
run slab        bash -c 'slabtop -o 2>/dev/null | head -n 15'
run disks       bash -c 'lsblk -o NAME,MODEL,ROTA,SIZE,TYPE,MOUNTPOINTS 2>/dev/null; df -hT; df -i'
run mounts      bash -c 'findmnt -t nfs,nfs4,fuse,overlay,tmpfs,xfs,ext4,btrfs,zfs 2>/dev/null | head -40'
# shellcheck disable=SC2016  # expansion intentionally deferred to the probe shell
run dstate      bash -c 'ps -eo pid,ppid,stat,wchan:24,etime,cmd 2>/dev/null | awk "\$3 ~ /D|Z/" | head -30'
run top-cpu     bash -c 'ps -eo pid,pcpu,pmem,rss,comm --sort=-pcpu 2>/dev/null | head -15'
run top-mem     bash -c 'ps -eo pid,pmem,rss,vsz,comm --sort=-rss 2>/dev/null | head -15'
run limits      bash -c 'ulimit -Sn; ulimit -Hn; cat /proc/sys/kernel/pid_max 2>/dev/null; cat /proc/sys/net/netfilter/nf_conntrack_count /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null'

# Network: config, sockets, counters, filters.
run links       bash -c 'ip -br a; ip route; ip rule; ip -s -s link 2>/dev/null | head -60'
run neigh       bash -c 'ip neigh; resolvectl status 2>/dev/null | head -30; cat /etc/resolv.conf 2>/dev/null; grep -E "^hosts:" /etc/nsswitch.conf 2>/dev/null'
run sockets     bash -c 'ss -ltnp; ss -s; ss -tan state established 2>/dev/null | wc -l'
run nstat       bash -c 'nstat -az 2>/dev/null | grep -Ei "retrans|listen|drop|discard|error|timeout|conntrack" | head -40'
# shellcheck disable=SC2016  # expansion intentionally deferred to the probe shell
run nic-stats   bash -c 'for i in /sys/class/net/*; do echo "-- ${i##*/}"; cat "$i"/statistics/{rx_dropped,tx_dropped,rx_errors,tx_errors,rx_missed_errors} 2>/dev/null; done'
run firewall    bash -c 'nft list ruleset 2>/dev/null | head -60; iptables-save 2>/dev/null | head -40'

# Change history: what moved recently.
run pkg-history bash -c 'rpm -qa --last 2>/dev/null | head -25; dpkg -l 2>/dev/null | tail -25'
run dnflog      bash -c 'tail -n 30 /var/log/dnf.rpm.log 2>/dev/null; tail -n 30 /var/log/dpkg.log 2>/dev/null'
run etc-recent  bash -c 'find /etc -type f -newermt "-3 days" -printf "%TY-%Tm-%Td %TH:%TM %p\n" 2>/dev/null | sort | head -40'
run logins      bash -c 'last -n 15 2>/dev/null; who 2>/dev/null; w 2>/dev/null | head -10'
run timers      bash -c 'systemctl list-timers --no-legend 2>/dev/null | head -20; crontab -l 2>/dev/null; ls /etc/cron.d /var/spool/cron 2>/dev/null'

# Hardware whispers.
run hw-errors   bash -c 'grep -Ei "mce|machine check|hardware error|edac|aer|pcie|thermal|throttl" /var/log/messages 2>/dev/null | tail -20; ras-mc-ctl --errors 2>/dev/null | tail -20'
run edac        bash -c 'cat /sys/devices/system/edac/mc/mc*/ce_count /sys/devices/system/edac/mc/mc*/ue_count 2>/dev/null'
run sel         bash -c 'ipmitool sel elist 2>/dev/null | tail -20'
# shellcheck disable=SC2016  # expansion intentionally deferred to the probe shell
run smart       bash -c 'lsblk -dnpo NAME 2>/dev/null | head -8 | while read -r d; do echo "-- $d"; smartctl -H "$d" 2>/dev/null | tail -3; nvme smart-log "$d" 2>/dev/null | grep -Ei "percentage_used|media_errors|temperature|available_spare"; done'

{
  echo
  echo "===== end of bundle ====="
  echo "Follow-ups that are NOT in this bundle (run deliberately, they cost more):"
  echo "  iostat -x 5 (long window)   nstat -s 1 (sampled deltas)   ss -tin"
  echo "  biolatency 1 10   offcputime 30   perf record -F 99 -g -- sleep 30"
  echo "  journalctl -u <unit> -b     systemctl cat <unit>"
} >>"$TXT"

chmod 600 "$TXT"
if have tar; then
  tar -czf "${TXT}.tar.gz" -C "$(dirname -- "$TXT")" "$(basename -- "$TXT")" && rm -f "$TXT" \
    && printf 'bundle: %s.tar.gz\n' "$TXT" && exit 0
fi
printf 'bundle: %s\n' "$TXT"
