# Subsystems field guide: system, security, and platform

systemd, boot and kernel, time, journald, hardware, security triage, containers, cloud, packaging.

Contents
- [10. systemd and services](#10-systemd-and-services)
- [11. Boot, kernel, and crash analysis](#11-boot-kernel-and-crash-analysis)
- [12. Time synchronization](#12-time-synchronization)
- [13. Logging and journald](#13-logging-and-journald)
- [14. Hardware health](#14-hardware-health)
- [15. Security triage and incident response](#15-security-triage-and-incident-response)
- [16. Containers, VMs, and Kubernetes nodes](#16-containers-vms-and-kubernetes-nodes)
- [17. Cloud instances](#17-cloud-instances)
- [18. Packages, upgrades, and patching](#18-packages-upgrades-and-patching)

## 10. systemd and services

**First three commands, always:**
```sh
systemctl status <unit>          # read Loaded: first, then Active:, then code=/status=
systemctl cat <unit>             # the real file + every drop-in, in apply order
journalctl -u <unit> -b --no-pager -n 100   # full output, not status's 10 lines
systemctl --failed; systemctl list-dependencies <unit> | head -30
systemctl show <unit> -p ExecMainStatus,Result,ExecMainCode,Restart,StartLimitBurst,FragmentPath,DropInPaths
```

**Exit-status taxonomy.** `status=NNN/<NAME>` in the 2xx range means **systemd's own
setup step failed, not your application** — the process never ran: `203/EXEC`
(bad `ExecStart=` path, not executable, bad shebang, missing interpreter, SELinux
deny on exec), `217/USER`/`218/-group` (unknown user/group), `200/CHDIR` (bad
`WorkingDirectory=`), `209/STDIN`-style FD problems, `210-219` namespace/`RootImage`
failures. Signal deaths show `code=killed, status=9/KILL` etc.; `code=exited,
status=1/FAILURE` is the app failing, so read the app's own logs and validate its
config with its own checker (`nginx -t`, `sshd -t`, `visudo -c`, `apache2ctl
configtest`). Also: `Result=` values (`exit-code`, `signal`, `timeout`,
`start-limit-hit`, `resources`, `mount-node-not-found`) tell you the failure class
directly.

**The reload gotcha.** After editing a unit (or a drop-in) you must
`systemctl daemon-reload` or the change is not seen; `systemctl restart` without it
restarts with the old definition. `systemctl edit <unit>` (never edit
`/lib/systemd/system/*` — package updates overwrite it; drop-in in
`/etc/systemd/system/<unit>.d/override.conf` wins). Empty assignment to clear a
directive (`ExecStart=` then the new value). After a crash loop hits
`StartLimitBurst`, `systemctl reset-failed <unit>` before retrying.
`systemd-analyze verify <unit>` and `systemd-analyze critical-chain <unit>` catch
syntax and ordering errors before you take the outage.

**Timeouts and shutdown pain.** `TimeoutStartSec`/`TimeoutStopSec` (default 90 s) kill
slow-starting or slowly-flushing services: SIGTERM at timeout, SIGKILL after
`TimeoutStopSec`; raise them for JVMs/databases, and prefer `Type=notify` + readiness
over a longer timeout. `KillMode=control-group` kills everything in the cgroup (the
usual cause of "my child process vanished"); `KillUserProcesses`/`scope` behaviour
explains "process died when I logged out" — use `loginctl enable-linger <user>` or a
real unit.

**Boot-ordering and targets.** `systemd-analyze blame/critical-chain`,
`systemctl list-units --type=service --state=degraded`,
`systemctl is-system-running` (degraded → `--failed`). `remote-fs.target`/`_netdev`
for NFS ordering, `network-online.target` is weaker than people assume
(`systemd-networkd-wait-online`/`NetworkManager-wait-online` must be enabled and only
waits for configured links). Masking (`systemctl mask`) is the way to stop an
unwanted unit; `systemctl revert <unit>` removes local drop-ins.

**Resource limits per unit.** `CPUQuota=`, `MemoryMax=`/`MemoryHigh=`, `TasksMax=`,
`LimitNOFILE=` (unit limits, **not** inherited by `su`/login shells — check
`ulimit -n` vs `systemctl show -p LimitNOFILE`), `Delegate=yes`, slices for grouping.
Inside a service, `systemd-cgls`/`systemd-cgtop` show the real hierarchy;
`systemd-run -p MemoryMax=500M -t bash` gives an ad-hoc sandbox to test a hypothesis
without touching production units.

## 11. Boot, kernel, and crash analysis

**Boot chain:** firmware/UEFI (or BIOS) → bootloader (GRUB/systemd-boot) → kernel +
command line → initramfs (drivers to reach root) → `/init` → `switch_root` → systemd
(PID 1) → targets/units. Failures localize by *where the console stops talking*: GRUB
rescue = bootloader/config; "dracut-initqueue timeout / Cannot mount /" = root not
findable (UUID, controller driver, LVM/RAID not in initramfs, iSCSI/NVMe-of network);
emergency target with a shell = a unit failed early, usually fstab; kernel panic with a
stack = kernel/driver/module, capture the trace verbatim (photo it if the console dies).

```sh
systemd-analyze; systemd-analyze blame | head; systemd-analyze critical-chain
systemctl list-units --state=failed
journalctl -b -1 -p warning --no-pager | tail -80     # previous boot: what it died doing
lsinitrd /boot/initramfs-$(uname -r).img 2>/dev/null | egrep 'nvme|ahci|xfs|dm-'   # dracut
ls /etc/initramfs-tools/scripts/local-top 2>/dev/null # Debian-style
cat /proc/cmdline; grub2-editenv - list 2>/dev/null || grub-editenv list
dmesg --level=err,warn | head -40
```

**Recovery routes.** At GRUB, `e` and append `systemd.unit=rescue.target`
(single-user-ish, mounts local FS) or `systemd.unit=emergency.target` (minimal, root
read-only, asks for root password). Add `rd.break` (RHEL/Fedora dracut) to stop in the
initramfs *before* `switch_root`: `mount -o remount,rw /sysroot`,
`chroot /sysroot`, fix, and on SELinux-enforcing systems `touch /.autorelabel` before
reboot or the context mismatch will lock you out. Debian uses
`init=/bin/bash` or `single` + `mount -o remount,rw /`. Reset the fstab entry, rebuild
the initramfs (`dracut -f` / `update-initramfs -u -k all`) and reinstall the bootloader
only after verifying UUIDs with `blkid`. Keep a known-good kernel in the menu and know
`apt mark hold` / `dnf --setopt=installonly_limit=` behaviour before a bad kernel ships
to the fleet. Secure Boot blocks unsigned third-party modules — test with it off, then
sign modules properly rather than leaving it disabled.

**Kernel panics/oops.** Enable kdump *before* you need it: `kexec-tools` +
`systemctl enable kdump` (RHEL family), `kdump-tools` (Debian/Ubuntu); dumps land in
`/var/crash/`. Analyze with `crash` (needs matching debuginfo) or `drgn` (live kernel
via `/proc/kcore`, or a vmcore — powerful for reading kernel data structures without a
rebuild). `sysctl kernel.panic`, `kernel.panic_on_oops`, `kernel.softlockup_panic`
control auto-reboot and dump policy; `netconsole` ships oops text to another host when
the console dies; `pstore/ERST` and `mcelog`/`rasdaemon` catch firmware-reported
errors. Also capture: the full `BUG:`/`RIP:` text, module list (`lsmod` vs `tainted:`
flags), and the exact kernel build (`rpm -q kernel-$(uname -r)`). Watchdog:
`watchdog: BUG: soft lockup - CPU#N stuck` = a CPU spinning in kernel; `hung task` = a
task blocked >120 s, almost always storage/NFS.

**Bisect.** For "which kernel/commit", install distro kernel series and bisect
boot/behaviour; for a specific regression, search the distro tracker and
`lore.kernel.org` with the exact `RIP:`/function name before spending a weekend.

## 12. Time synchronization

`timedatectl status` → `chronyc tracking` + `chronyc sources -v` (+ `chronyc sourcestats
-v`). `ntpd` is retired on modern distros; chrony is the default (and `systemd-timesyncd`
is a client-only stub — not a substitute on servers).

Symptoms of skew: TLS "certificate is not yet valid"/expired, Kerberos `KRB5KRB_AP_ERR_
TICKET_SKEW` (>5 min), TOTP failures, distributed consensus/replication stepping down,
log correlation impossible, cron firing at the wrong wall time, file timestamps in the
future making make/rsync skip work. Treat a wrong clock as an incident, not a curiosity.

```sh
timedatectl show --property=NTPSynchronized,Timezone,RTCTimeUSec
chronyc tracking          # System time offset, RMS, last offset
chronyc sources -v; chronyc sourcestats -v
journalctl -u chronyd --since '-1 hour' | tail -40
ss -lunp | grep 123       # is chrony even serving?
```
`makestep 1.0 3` lets a freshly started or migrated VM *step* for the first few
corrections, then slew — without it, a guest waking from pause with a multi-second
error will take hours to catch up. On VMs prefer the hypervisor clock:
`refclock PHC /dev/ptp0 poll 3 dpoll -2 offset 0` (Azure/AWS/GCP and KVM with
`kvm-clock`+PTP exposed), verify with `ls /dev/ptp*` and
`cat /sys/devices/system/clocksource/clocksource0/current_clocksource`. Check UDP/123
egress, `pool`/`server ... iburst`, chroot/`privdrop` user setup, and don't run two
time daemons. A VM drifting badly after suspend/live-migration is a hypervisor/host
problem — check the host's clock too, since guest time follows a broken host.

## 13. Logging and journald

```sh
journalctl --disk-usage; journalctl --list-boots
journalctl -b                       # this boot; -b -1 previous; -k kernel only
journalctl -u <unit> --since "10 min ago" --until "2 min ago" --no-pager -o all
journalctl -p 3 -xb                 # this boot, priority err and above
journalctl -f --since=-5m           # follow; -o json-pretty for machine parsing
sudo journalctl --flush             # move volatile journal to /var now
systemd-tmpfiles --create --prefix /var/log/journal
```
**Why your logs are gone:** `Storage=auto` (the default) writes to
`/var/log/journal` only **if that directory exists**; otherwise it is volatile in
`/run/log/journal` and evaporates on reboot. Fix: `mkdir -p /var/log/journal` +
`systemctl restart systemd-journald` (journald creates it mode 2755 group
systemd-journal), or set `Storage=persistent` in a drop-in at
`/etc/systemd/journald.conf.d/` so it fails loudly instead. Set
`SystemMaxUse=` **and** `SystemKeepFree=` — `SystemMaxUse` is a ceiling, not a
guarantee, and journald also backs off the free-space floor, so a disk at 95% will not
give you 2 G of journal. Kernel ring buffer (`dmesg`) is fixed-size and volatile;
journald is what makes it durable — pull `journalctl -k -b -1` immediately after a
panic-adjacent event.
Rate limiting (`RateLimitIntervalSec`/`RateLimitBurst`) silently drops repeated service
logs: "logs missing" often means "log flooded". `Seal=yes` for tamper evidence; ship
logs off-host (`systemd-journald` + `systemd-journal-remote`, rsyslog `imjournal`, or an
agent) so a compromised host cannot delete its own trail. Validate rsyslog config with
`rsyslogd -N1`. journald config changes need a restart, and package updates can reset
files you edited in `/etc` — use drop-ins.

## 14. Hardware health

**The machine often tells you in advance.** Read the whispers:

```sh
journalctl -k -b -1 --no-pager | grep -Ei 'panic|oops|BUG:|watchdog|lockup|mce|machine check|hardware error|edac|aer|pcie|thermal|caterr'
ras-mc-ctl --errors ; ras-mc-ctl --summary            # decoded MCE/EDAC (prefer over mcelog)
grep -r . /sys/devices/system/edac/mc/mc*/ce_count /sys/devices/system/edac/mc/mc*/ue_count
smartctl -a /dev/sdX                                  # Reallocated_Sector_Ct, Current_Pending_Sector
nvme smart-log /dev/nvme0                             # percentage_used, media_errors, temperature
nvme error-log /dev/nvme0; nvme list
sensors; sensors-detect                               # lm-sensors
ipmitool sdr type Temperature; ipmitool sdr type Fan; ipmitool sdr type "Power Supply"
ipmitool sel elist | tail -30                         # out-of-band: BMC saw it too
lspci -vvv | grep -A2 -i 'correctable error'          # PCIe AER
dmidecode -t memory | grep -i 'Locator\|Size\|Speed'  # map EDAC to a physical slot
```
A single corrected error (CE) is noise. A **CE count rising on one DIMM** is a part to
replace on your schedule, not after the uncorrected error (UE) crashes the box.
Decode with `rasdaemon`; raw MCE bank hex is not meant for humans, and legacy `mcelog`
is Intel-focused and superseded on modern/AMD platforms. Always check the BMC SEL as
well — the OS log rotates, the SEL does not.
Alert on deltas, not absolute values: `Reallocated_Sector_Ct > 0`,
`Current_Pending_Sector > 0`, rising `media_errors`, `percentage_used` approaching 100,
`wear_leveling_count` low, temperature above the vendor threshold, fan below minimum,
PSU redundancy lost. Note that `smartd` health "PASSED" and a rising reallocated count
are not contradictory — the attribute trend is the signal, not the pass/fail bit.

## 15. Security triage and incident response

**Order of work: contain, preserve, then analyze.** Volatile data first, in this
priority (RFC 3227 discipline): live process/memory and network state → logged-in
users and their commands → files modified/accessed recently → disk and forensic image →
backup/archive and logs elsewhere. Snapshot VM state instead of powering off; power-off
destroys memory-resident evidence and, for ransomware/cryptominer cases, sometimes the
decryption material.

```sh
date -u; uptime                                   # anchor the timeline
ps auxfww; ps -eo pid,ppid,user,lstart,etime,cmd --sort=-etime | head -40
ls -la /proc/<pid>/{cwd,exe,fd}                   # deleted binary running? (/proc/<pid>/exe)
cat /proc/<pid>/environ | tr '\0' '\n'            # env may name the operator/config
ss -tunap; ss -tan state established              # who is talking to whom (exfil/C2)
lsof -i -nP; ss -ltnp                             # unexpected listeners
last -Fa; lastb -F | head -30; who -a; w         # logins, failed attempts
journalctl _COMM=sshd --since "-7 days" | grep -Ei 'accepted|invalid|Disconnected'
find / -xdev -mtime -1 \( -type f -o -type d \) -not -path '/proc/*' -not -path '/sys/*' 2>/dev/null | head -60
crontab -l -u <user>; ls -la /etc/cron* /var/spool/cron*
systemctl list-units --all --state=loaded | egrep -v 'systemd|dbus' ; systemctl list-timers --all
ls -la /etc/systemd/system/ /root/.config/autostart/ ~/.ssh/ /etc/ssh/sshd_config.d/
cat /etc/passwd /etc/shadow | awk -F: '($3==0){print $1}' ; grep -c '^+' /etc/sudoers /etc/sudoers.d/*
ip neigh; ip route; cat /etc/resolv.conf; nft list ruleset; iptables-save 2>/dev/null
rpm -Va --nomtime 2>/dev/null | head -40  ||  debsums -c 2>/dev/null | head -40
cat /etc/ld.so.preload 2>/dev/null; ldconfig -p | wc -l   # LD_PRELOAD rootkit vector
env | grep -i proxy; find / -xdev -perm -4000 -type f 2>/dev/null   # new SUID
```

**Persistence checklist (Linux):** cron/at, systemd units+timers+drop-ins (including
`/etc/systemd/system/*.wants/`), `rc.local`/profile/`bashrc`/`zshrc`, `~/.ssh/authorized_keys`
(and `authorized_keys2`, `~/.ssh/config`, `PermitRootLogin`/`AuthorizedKeysFile` edits),
`/etc/ld.so.preload` + `ld.so.conf.d` hijacks, PAM stack edits, new uid-0 accounts,
`sudoers.d`, modified binaries (verify with `rpm -Va`/`debsums`, and compare
`command -v` order — PATH shadowing), web-shell in docroots, container images and
k8s `ClusterRole`s, `git` hooks, `motd`/`pam_exec` hooks, kernel modules (`lsmod`,
taint flags, `/sys/module/*/srcversion` vs the package).

**MAC (SELinux/AppArmor) triage.** `getenforce` + `sestatus` and `aa-status`. Denials:
`ausearch -m avc -ts recent` / `journalctl -t setools -t audit` /
`grep avc /var/log/audit/audit.log`. Read the denial before you act: `type=avc
denied ... scontext=... tcontext=... tclass=...` says exactly which access is missing.
Use `audit2allow -i <(ausearch -m avc -ts recent) -p mymodule --list` to *understand*
it, build a targeted policy module, and never ship `permissive` or `disabled` as a fix
— especially not on RHEL 9/10 where `SELINUX=disabled` in the config file is no longer
honoured (needs `selinux=0` on the kernel command line). Relabeling: `restorecon -RFv
<path>` for wrong contexts (a moved/re-unpacked file is the usual cause),
`touch /.autorelabel && reboot` for a system-wide relabel. Wrong context after
`cp -a`/tar-restore is one of the most common "it worked before" bugs. AppArmor:
`aa-status`, `aa-logjson`/`dmesg | grep AppArmor`, `aa-genprof`/`aa-audit` for
constrained profiles.

**Hardening verification (the boring 10):** SSH config validated with `sshd -t` *and*
an open session kept alive while you reload; key-only auth; `sudo` logging present;
crypto policy (`update-crypto-policies --show`, `crypto-policies` on RHEL-family —
legacy TLS/SSH failures after an OS upgrade are usually this); firewall default-deny
with a saved *and* applied ruleset; `dnf`/`apt` security updates and `needs-restarting
-r` for reboot-required; `faillock`/`pam_faillock` or `fail2ban` (note: journal
backend and nftables ban actions are now the default on Debian 13+); MAC enforcing;
auditd rules loaded; certificates expiring (`openssl x509 -enddate -noout -in`);
`lynis`/CIS scan with results reviewed rather than auto-remediated.

**Kernel CVE and patch verification.** A patched package ≠ patched running system:
kernel code is boot-time, so verify `uname -r` against the installed
`rpm -q kernel`/`dpkg -l linux-image` and reboot (or apply a livepatch: `kpatch`,
`kernelcare`, Canonical livepatch — `kpatch list`, `needrestart`/`needs-restarting -r`).
`dnf updateinfo list cves --installed` / `unattended-upgrade --dry-run` /
`debian-security-support` give the residual exposure. Restart long-running services
after library upgrades or they keep the old, vulnerable code mapped in memory
(`needrestart` finds them).

## 16. Containers, VMs, and Kubernetes nodes

**The mental model:** namespaces decide what a process **sees**; cgroups decide what it
may **use**. Neither is a security boundary by itself, and containers are ordinary host
processes — from the host you can always see and act on them.

- `ps aux` inside a container shows only that PID namespace and not the host PIDs, not
  the cgroup, and not the throttling. From the host, find it: `crictl ps` /
  `docker ps -q`, `cat /proc/<pid>/cgroup`, `systemd-cgls`, `nsenter -t <pid> -m -p`.
- `/proc/loadavg`, `/proc/meminfo`, `/proc/cpuinfo`, `top`, `vmstat`, `iostat` inside a
  container report the **host** unless the toolset is cgroup-aware. Never size an app
  from those numbers inside a container; read
  `/sys/fs/cgroup/.../{cpu.max,cpu.stat,memory.max,memory.current,io.max}` instead.
- `OOMKilled` (container's own cgroup limit exceeded, decided by the kernel and
  reported by containerd/CRI-O) ≠ **node eviction** (kubelet acting on node pressure
  with its own thresholds) ≠ `CrashLoopBackOff` (an app exiting non-zero). Check
  `kubectl describe pod` `Last State: Terminated Reason/Exit Code`, `dmesg -T | grep
  oom`, `/sys/fs/cgroup/.../memory.events` (`oom_kill` counter), and kubelet logs.
  The runtime's OOM-detection logic differs between containerd and CRI-O.
- `exit code 137` = 128+9 (SIGKILL: usually OOM or a stop timeout); `143` = 128+15
  (SIGTERM, graceful); `126` not executable/permissions; `127` binary or interpreter
  missing (bad shebang, missing shared library — verify with
  `docker run --rm -it image sh -c 'ldd /bin/foo'`).
- `--pid=host`, `--privileged`, `--network=host`, mounted `/sys`/`/dev`/`/` (a `hostPath`
  mount is an instant node root), `--security-opt label=disable` and SELinux
  container-context flags (`:z`/`:Z`) — know which are in play before diagnosing.
- Missing cgroup v1 support is now the norm: systemd 259 dropped cgroup v1, RHEL 10
  removed it, Ubuntu 26.04 requires v2 and blocks the upgrade from a v1-booted host. Old
  container images/JVM agents/tooling that mount v1 hierarchies break on those hosts.
- Storage/overlay: full upperdir or a full image store shows as container write failure
  with a healthy host `df` (check `docker system df`, `/var/lib/containerd`, and the
  LV backing the pool); `overlayfs` cannot be exported over NFS; inode exhaustion in the
  image store is common with many small-file images.
- Readiness: `systemd` inside containers needs `--cgroupns=private` and care with
  tmpfiles/DBus; distroless images have no shell — debug from the host with
  `nsenter`/`drgn`/`kubectl debug --target` (ephemeral containers) rather than
  installing tools into the image.
- VM-specific: ballooning steals memory the guest thinks it has (`balloon` driver,
  `virsh dommemstat`), virtio ring limits cap IOPS below the underlying device, host
  CPU steal (`%st` in `top`) means the hypervisor is oversubscribed — no guest-side
  tuning fixes it, escalate to the host owner.

## 17. Cloud instances

`dmesg -T | tail`, `cloud-init status --long`, `journalctl -u cloud-init* --since boot`
for first-boot failures (metadata timeouts, user-data script exit codes, `sshkey`
fetch, IMDSv2 token issues). Reach IMDS with a token (`PUT /latest/api/token`,
`X-aws-ec2-metadata-token-ttl-seconds`) and honour its rate limits.
Root cause categories that dominate cloud tickets: EBS/Azure-disk IOPS/throughput
burst credit exhaustion (throttling looks like a slow disk, not a broken one),
instance store wiped on stop/start, NVMe device naming (`/dev/nvme0n1` vs
`/dev/sda1` in old AMIs) and `nvme_instance_name`/udev rules, ENI source/dest check
for NAT/routing boxes, security groups vs NACLs vs host firewall (three independent
filters — test each), Elastic IPs and NAT gateway ports, load balancer health checks
(failing because the app binds `127.0.0.1` or the SG does not allow the LB subnet),
time drift on a migrated host, and clock/`chrony` differences from the region's
metadata endpoint. Autoscaling replaces the box you were debugging — snapshot or
detach it before investigating, and remember CM/IaC will revert a manual fix at the
next apply/converge.

## 18. Packages, upgrades, and patching

**Before any upgrade:** read-only filesystem check, backups/VM snapshot, `--dry-run`
of the transaction, read the release notes for *breaking* changes (not features),
confirm a rollback path, and schedule the reboot. Then:

```sh
apt-get -s upgrade                       # simulate; also apt list --upgradable
dnf -q --assumeno update ; dnf -q updateinfo list security
dnf -q updateinfo info CVE-2026-XXXX     # advisory lookup
debsums -c 2>/dev/null | head            # dpkg integrity
rpm -qa --last | head; rpm -Va 2>/dev/null | grep '^..5' | head
uname -r; ls /boot; rpm -q kernel --last || dpkg -l 'linux-image*' | head
```
**Recovery:** dpkg interrupted → `dpkg --configure -a`, then `apt-get check` and
`dpkg --audit` (clean exit + no output = state coherent), then
`apt-get -f install` **after** reading its proposed removals in a simulate run; fix
the repo/pin/hold conflict instead of forcing. Dpkg lock held → find the owning PID
(`fuser -v /var/lib/dpkg/lock-frontend`, `ps`) rather than deleting lock files.
RPM/dnf: `dnf history list`, `dnf history info <id>`, `dnf history undo <id>` (or
`last`), `dnf mark remove/install`, `rpm --rebuilddb` for a damaged RPM DB
(after copying `/var/lib/rpm`). Never mix distro and vendor repos for the same stack,
and never `--nodeps`/`--force` on a production system as a first move.
Kernel/patch state: `needs-restarting -r` (RHEL family) reports reboot-required;
`needrestart` (Debian family) lists services holding old libraries; livepatch
(`kpatch`, `livepatch`, `Canonical livepatch`) fixes selected kernel CVEs without a
boot but has a coverage limit and its own support contract. Verify the fix actually
landed by re-running the query that reported it (`rpm -q <pkg>`,
`dnf updateinfo list cves --installed`) — the package database will call a host
"patched" while it still runs the vulnerable, un-booted kernel.
Held/pinned: `apt-mark showhold`, `/etc/apt/preferences.d/`,
`dnf installonly_limit` / `dnf versionlock` / module streams
(`dnf module list`) — and after Fedora's dnf5 switch, note repo config moves
(`/etc/yum.repos.d` may be empty while repos live under `/usr/share/dnf5/repos.d`) and
that old DNF4-style subcommand aliases differ.
