# Change safety, evidence, and records

The discipline that keeps a 30-year record clean. Everything here exists because
someone (often the author) once did the shortcut version.

Contents
- [1. Command classification](#1-command-classification)
- [2. The pre-flight checklist before any mutation](#2-the-pre-flight-checklist-before-any-mutation)
- [3. Irreversible operations: extra gates](#3-irreversible-operations-extra-gates)
- [4. Backup and rollback that you can actually execute](#4-backup-and-rollback-that-you-can-actually-execute)
- [5. Verification: proving the fix](#5-verification-proving-the-fix)
- [6. Records: notes, timelines, postmortems](#6-records-notes-timelines-postmortems)
- [7. Escalation and communication](#7-escalation-and-communication)
- [8. Red lines](#8-red-lines)

## 1. Command classification

Classify before proposing. If in doubt, it is the higher class.

**A — read-only.** Inspect, do not alter: `cat/ls/stat/find/df/du/ps/pmap/lsof/ss/ip
-show/nstat/sar/iostat/vmstat/mpstat/pidstat/top/journalctl/dmesg/blkid/lsblk/lscpu/
rpm -qa/dpkg -l/sysctl -a`, `strace`/`perf`/`bpftrace` *observers* (bounded duration —
tracing a hot path is functionally a load injection, so treat long traces as B),
`rpm -Va`/`debsums` (reads only, but heavy on I/O — schedule it).
→ Run freely. Say what you are looking for.

**B — reversible state change.** Undo is known and cheap:
`systemctl start/stop/restart/enable/disable/edit`, `sysctl -w`, `mount`/`umount`
(non-root, non-shared), `ip addr/route/rule add/del`, `tc` qdisc changes,
`nft add/delete rule` (with the ruleset saved first), package install/remove/update,
`journalctl --vacuum-*`, `chmod/chown` on a single known file, `kill`/`systemctl kill`
a misbehaving process, config edits *with a timestamped backup and a validated syntax
check*, container start/stop/rm, `crontab` edits, `firewall-cmd --permanent` + reload.
→ Before running: state the revert command, the blast radius (which units/hosts/users),
and how you will verify. Then get a go-ahead unless the change was explicitly
authorised and is obviously in scope. Prefer `--dry-run`/`-t`/`-n` first.

**C — destructive or irreversible.** Data, identity, boot, or security posture:
`rm -rf` (anything recursive/forced), `dd`, `mkfs.*`, `fdisk/parted/sfdisk` writes,
`wipefs`, `lvremove/pvremove/vgreduce --removemissing --force/vgcfgrestore`, `pvmove`,
`mdadm --create/--zero/--grow`, `zfs destroy`, `btrfs check --repair`,
`fsck`/`xfs_repair` on anything mounted or without an image, `truncate -s`,
`> /dev/sdX` or any redirect onto a block device, `chmod -R 777`, `chown -R` on `/`,
`userdel`/`groupdel`/`passwd` for others, `visudo`/sudoers changes, firewall flush
(`nft flush ruleset`, `iptables -F`), `systemctl mask`, GRUB/bootloader/install
(`grub-install`, `grub2-mkconfig`, `efibootmgr`), initramfs rebuilds, kernel
install/removal on a remote host, `reboot`/`shutdown`/`poweroff`, `kdump` config
changes on a live node, `rpm --force/--nodeps`, `dpkg --force-*`, database
migrations/purges, `curl ... | sh`, `git push --force`, secrets rotation,
`ip link set down` on the interface you are logged through.
→ **Stop.** Name exactly what can be lost, show the backup/snapshot and where it
lives, give the recovery procedure and how long it takes, then require explicit
confirmation from the user. Never chain a Class C command onto a Class A one in a
single block. Never run one speculatively "to see what happens".

**The remote-access trap.** Any command that can sever your own session
(`iptables`/`nft` rule, SSH config, `ip addr del`, interface bounce, `systemctl restart
sshd`, firewall default-deny, `selinux=1` on a mislabeled box, PAM changes, disk
detach) is Class C even though it is "just a restart", because you cannot fix it from
the console you just lost. Requirements: out-of-band access confirmed (console/BMC/
serial/rescue), a second session kept open, a self-reverting timer
(`systemctl start sshd-rollback.timer` or `at now + 5 min` reverting the change), and
`sshd -t`/`nft -c -f` validation *before* applying.

## 2. The pre-flight checklist before any mutation

Say it out loud (in the reply) for B and C:

1. **Goal** — the observable outcome, and the metric that will show it.
2. **Current state** — captured baseline (same commands, same window, as post-check).
3. **Change** — the exact command, one variable, with the file backups it implies.
4. **Blast radius** — services, hosts, users, data touched; can it hit more than intended?
5. **Rollback** — the exact command(s), tested if possible, and the time to restore.
6. **Failure mode** — if this half-applies, what is the worst state and how do you exit it?
7. **Escape hatch** — out-of-band access, live session kept, snapshot present.
8. **Validation** — the config test to run first (`sshd -t`, `nginx -t`, `visudo -c`,
   `nft -c -f`, `systemd-analyze verify`, `fdisk -l`, `mount -a` dry-check via
   `findmnt`), and the post-change check.
9. **Timing** — now or in a window; who is affected and who has been told.
10. **Reversibility of the reversibility** — does rollback lose data written after the
    change (e.g. restoring a config or a snapshot discards new writes)? Say so.

If you cannot state 5 and 6, you do not have a change plan; you have a hope.

## 3. Irreversible operations: extra gates

- **Devices and partitions.** Dump the layout first:
  `sfdisk -d /dev/sdX > sdX.pt.txt`, `parted /dev/sdX unit B print > sdX.parts.txt`,
  `lsblk -fp`, `blkid`, `mdadm --examine --scan`, `pvs;vgs;lvs`,
  `dd if=/dev/sdX of=/root/sdX.head bs=1M count=64` (partition table + headers), and a
  real filesystem/device image where the data matters. Confirm the target device name
  twice: `lsblk -o NAME,SIZE,MODEL,SERIAL,MOUNTPOINTS` and match the *serial/model*,
  not the `/dev/sdX` letter (enumeration changes across reboots and controllers).
- **`dd`.** `if=`/`of=` written out and re-read; `bs=` chosen deliberately;
  `status=progress`; `oflag=direct` for device writes; `count=` for a bounded test;
  no `of=` on a mounted or in-use device (`lsof`, `swapon --show`, `findmnt`); unmount
  and `sync` first; `conv=fsync` at the end. One transposed letter is an outage.
- **`fsck`/`xfs_repair`/`btrfs check`.** Never on a mounted filesystem (the exception
  is ext4 `fsck` with `-C` on a journaled FS with `e2fsck -p`, which still means
  unmounted in practice). Backup superblock first (`mke2fs -n` shows alternates;
  `e2fsck -b <sb>`), take a block image if the data is irreplaceable, run the
  read-only pass first (`fsck.ext4 -n`, `xfs_repair -n`, `btrfs check`), record the
  exact kernel error strings before repairing (repair destroys the evidence upstream
  will ask for).
- **LVM.** Copy `/etc/lvm/backup/<vg>` and `/etc/lvm/archive/` off-host before any
  `vgcfgrestore`, `pvmove`, `lvconvert`, `lvremove`, or metadata repair. Know that
  `vgcfgrestore` restores metadata, not data, and that thin-pool metadata has separate
  recovery rules. `lvm` commands accept `-t` (test mode) — use it.
- **RAID.** Image members and `mdadm --assemble --readonly` on the images before
  experimenting. Never `mdadm --create` over an array you have not examined: it
  destroys superblocks irreversibly. Back up superblocks:
  `mdadm --examine /dev/sdX1 > sdX1.examine.txt`.
- **Upgrades.** Snapshot the VM or take a verified backup; run the transaction
  simulation and *read the proposed removals*; keep the previous kernel installed and
  bootable; confirm the reboot is authorised; check out-of-band console access; never
  upgrade a fleet in one wave.
- **Secrets/auth.** Never lock yourself out: validate with `sshd -t`/`visudo -c`/
  `pam-auth-update`, keep a root session open, and have console access before touching
  PAM, sudoers, SSH keys, or account databases.
- **Downloads.** Never `curl | sh` without reading the script; verify checksums and
  signatures; prefer distro packages. Do not run third-party "rootkit scanners" or
  kernel modules on a production box without reviewing what they load.

## 4. Backup and rollback that you can actually execute

- A backup you have not restored is a hope, not a backup. **Restore-test** on a
  schedule, ideally on different hardware and by a different person. Verify with
  `restic check --read-data-subset` / `borg check --verify-data` /
  `tar -tzf` / checksums, not just exit codes.
- Minimum set to resurrect a Linux host: partition table + filesystem types/UUIDs,
  `/etc` (tar with permissions and SELinux contexts:
  `tar --xattrs -czf /backup/etc.$(hostname).$(date +%F).tar.gz /etc`), package list
  (`rpm -qa > pkgs.txt` / `dpkg --get-selections > pkgs.txt`), kernel version, boot
  config (`/boot`, `/etc/default/grub`, `grub2-editenv - list`), fstab, network config
  (`ip a`, `nft list ruleset`, NetworkManager/systemd-networkd files), cron/timers/units
  (`systemctl list-unit-files --state=enabled`), users/groups/sudoers, certificate and
  key inventory (locations, not secret values, in a safe store), database dumps with
  consistent snapshots, and the *procedure* written down.
- Layered protection: 3-2-1 (three copies, two media, one off-site) plus immutable
  (WORM/object-lock or append-only) copies, air-gapped enough that ransomware on the
  host cannot reach them. Back up *before* every planned change.
- Cheap, effective pre-change snapshot on Linux: LVM snapshot
  (`lvcreate -L 20G -n pre.snap vg/lv` — mind COW exhaustion; thin snaps share the pool
  and can fill it), `btrfs subvolume snapshot -r`, `zfs snapshot`, a VM
  snapshot/checkpoint, `mdadm` bitmap-off copy, or `dd` of a small partition. Record
  the exact restore command next to it and note performance impact (COW snapshots
  slow writes; do not leave them for days).
- Roll-forward vs roll back: for config, keep timestamped copies
  (`cp -a file file.bak.$(date +%F-%T)`) and diff them before/after
  (`diff -u file.bak… file`); for databases, prefer a tested restore + replay over a
  blind rollback; for containers/images, immutable tags you can point back to.
- Backups must be *recoverable by the person on call at 04:00*, which means the runbook
  lives with the backup, not only in your head.

## 5. Verification: proving the fix

Verification is part of the change, not an afterthought.

1. Same measurement as the baseline: same command, same window, same target.
2. Local, then dependent: the service is up (`systemctl is-active`, port listening,
   health endpoint), the feature works (an actual request/transaction, not just a
   process), the callers work (test from the client's network path, not only localhost).
3. Error counters flat: the counter that was climbing has stopped climbing
   (`nstat -s 1`, `ethtool -S` deltas, journal error rate, `dmesg -T` silence).
4. Duration: watch past the failure interval — many faults are periodic (cron, timers,
   GC, log rotation, nightly jobs). Say how long you will watch and do it.
5. Negative check: prove the fix is *why* it works when feasible (revert briefly in a
   test environment, or reproduce the failure in a VM with the change removed).
6. Persistence across the boundary the change does not survive: `sysctl -w` needs a
   `/etc/sysctl.d/` file; `nft add rule` needs a saved ruleset; `ip addr add` needs
   NetworkManager/networkd config; `systemctl edit` needs `daemon-reload` to have run;
   a package install needs to be recorded in the CM/IaC repo or the next converge
   removes it. State explicitly what makes it durable, and do the durable step.
7. Report the numbers: "`w_await` 180 ms → 3.4 ms, `aqu-sz` 8 → 0.2, zero
   `nvme media_errors` delta over 24 h" beats "fixed".
8. Close the loop: update the ticket/runbook/alert, add the missing monitor, and file
   the follow-up that prevents recurrence. If you discovered a new latent risk, name it
   even if it is out of scope.

## 6. Records: notes, timelines, postmortems

Write contemporaneously during an incident; you will not remember it accurately later.
Separate **observation** (measured), **inference** (reasoned from measurements), and
**action** (what was done, by whom, when) — mixing them is how postmortems turn into
myths.

Incident note template:
```
Incident: <id>  Severity: <S>  Status: [mitigated|resolved|rca-published]
Impact: <what/who/how much, from first abnormal timestamp to resolution>
Summary (2-4 sentences, no jargon, mechanism named)
Timeline (UTC, machine-sourced):
  HH:MM  first abnormal metric/alert  (evidence: <query/graph/log line>)
  HH:MM  <observation>
  HH:MM  <action taken + command + actor>
  HH:MM  verification: <metric back to baseline>
Root cause: <mechanism, in one paragraph; commit/config/component if known>
Trigger:    <what set it off>
Contributing: <detection gap, missing guardrail, docs gap, capacity, fatigue>
Mitigation vs fix: <what bought time; what actually removes it>
What ruled out: <hypotheses + the check that killed each>
Follow-ups: <owner, date, verifiable acceptance test>
Detection: <alert/SLO that would have caught it; add it>
Reproduction/runbook update: <link>
```
Also record the *evidence bundle*: the exact commands and outputs, the log excerpts,
`journalctl -b -N -p warning > /case/boot.log`, `sosreport`/`mktar` if a vendor case is
open, and the `uname -r` + package versions at the time. Attach the reproduction to
upstream reports (distro tracker, kernel `lore`) with the minimal test case — the same
discipline that gets you an answer in hours instead of weeks.

## 7. Escalation and communication

- Announce at start, at each material change, and at resolution. Unreported changes
  create second incidents.
- Escalate up with: impact, timeline, what you ruled out, what you tried, what you
  need (access, decision, expertise, hardware, vendor). A handoff that lists the dead
  ends saves the next person an hour.
- Vendor support: open the case with the bundle attached (distro + exact release,
  kernel, package versions, reproduction, full logs, `sosreport`, hardware model and
  firmware). Silence your changes while the case is live so the engineer sees a stable
  system.
- Ask for help earlier than feels comfortable. Two hours of solo thrashing is not
  diligence; it is latency for the affected users.
- If a stakeholder's instruction conflicts with a safety rule (skip the backup, run the
  fsck now, disable SELinux to make the error go away), state the risk once in plain
  terms, offer the safe alternative and its cost, and **put it in writing**. Documented
  disagreement is what protects the organisation later — and you. If the risk is data
  loss or a security control being disabled, say clearly that you recommend against it
  and what you need to proceed safely.
- Never hide or quietly fix a mistake. Revert, report, explain the mechanism, propose
  the guardrail. The recovery is faster and the trust survives; concealment does neither.

## 8. Red lines

Things a veteran does not do, even at 04:00, even under a VP:

- No `fsck`/`xfs_repair` on a mounted filesystem, no `--repair` on the "maybe it fixes
  it" theory.
- No `dd`, `mkfs`, partition write, or `mdadm --create` on a device whose identity was
  not confirmed by model/serial and by `lsblk`/`findmnt`.
- No unquoted `rm -rf "$VAR/"`, no `rm -rf ${DIR}/*` with an unset `DIR`, no `chmod -R`
  on `/`, no `chown -R` on a system directory. Echo the expanded command first
  (`printf '%q ' "$@"`) or use a safe wrapper.
- No firewall ruleset flush or SSH/PAM/sudoers change without out-of-band access and a
  self-reverting timer.
- No reboot of a machine you did not check for: other tenants/VMs, in-guest databases,
  quorum members (one node of a cluster can cascade), HA failback, a job mid-write,
  unflushed state, or a licence manager as the only host.
- No disabling security controls (SELinux/AppArmor enforcing, auditd, TLS verification,
  host key checking, MFA) as a "troubleshooting" step left in place. Temporary,
  documented, reverted, verified reverted.
- No production change outside a window without an approved, written exception.
- No `curl | sh`, no unreviewed binary, no kernel module from a random repo.
- No "temporary" hand-edits to a CM-managed system without also fixing the source and
  telling the team which file will win at the next converge.
- No destructive action taken on the assumption the user meant it. Ask.
