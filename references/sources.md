# Sources, divergence map, and how to re-verify

Two parts: (1) how to establish *current* facts instead of trusting this file or your
training data; (2) a dated divergence snapshot so you know which assumptions to test
first.

Contents
- [1. Re-derive current state on the target](#1-re-derive-current-state-on-the-target)
- [2. Canonical references](#2-canonical-references)
- [3. Divergence snapshot (dated — re-verify)](#3-divergence-snapshot-dated--re-verify)
- [4. Where upstream truth lives per subsystem](#4-where-upstream-truth-lives-per-subsystem)

## 1. Re-derive current state on the target

Never advise from memory about versions, defaults, file locations, or command syntax.
Establish it in one shot, then reason:

```sh
cat /etc/os-release; getconf LONG_BIT; uname -r -v -m       # distro + kernel + arch
rpm -q --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{arch}\n' systemd iproute2 iptables nftables \
  2>/dev/null || dpkg -l systemd iproute2 nftables iptables util-linux procps 2>/dev/null
systemctl --version | head -1; ip -V; nft --version | head -1; ss -V
ls /sys/fs/cgroup | head; stat -fc %T /sys/fs/cgroup        # cgroup2fs = v2
getenforce 2>/dev/null; aa-status 2>/dev/null | head -3
readlink -f /etc/resolv.conf; grep ^hosts: /etc/nsswitch.conf
systemctl is-active firewalld nftables sshd chronyd systemd-resolved 2>/dev/null
update-crypto-policies --show 2>/dev/null                    # RHEL-family TLS baseline
sed --version 2>/dev/null | head -1 || sed -i '' 2>&1 | head -1   # GNU or BSD userland
```

For anything released-in-the-last-year (kernel behaviour, distro defaults, tool
syntax), confirm against the distro release notes and the project's own changelog
before stating it. If the web/doc tools are available in the session, use them:
`https://<distro>/release-notes`, `https://github.com/<project>/releases`,
`lore.kernel.org` search for a regression, and the distro bug tracker for "known issue
with this kernel".

## 2. Canonical references

Kernel and core userspace
- kernel.org documentation index (all subsystems, ABI, sysctls, fs, locking, PM):
  https://docs.kernel.org/
- Kernel release/LTS table with projected EOL dates:
  https://www.kernel.org/category/releases.html and https://www.kernel.org/releases.html
- Linux man-pages project (the authoritative `man 2`/`man 7` — read `man 7 cgroups`,
  `man 7 proc`, `man 7 ip`, `man 7 tcp`, `man 7 sched`, `man 7 namespaces`):
  https://man7.org/linux/man-pages/
- Distro manpage mirrors for the *installed* version:
  https://manpages.debian.org/ , https://manpages.ubuntu.com/manpages/ ,
  https://www.man7.org/linux/man-pages/index.html
- LWN (kernel development analysis, regression discussions): https://lwn.net/
- Kernel mailing list archive (search the exact oops function name):
  https://lore.kernel.org/lkml/

systemd and freedesktop
- systemd docs (all unit directives, daemon semantics, cgroup delegation):
  https://www.freedesktop.org/software/systemd/man/ and https://systemd.io/
  (notably `https://systemd.io/CGROUP_DELEGATION/`, `https://systemd.io/ARCHITECTURE/`)
- D-Bus, journald API, `systemd.analyze`: same index above.

Distro operations documentation (read these before generic blog advice)
- Red Hat / RHEL / CentOS Stream (incl. performance & monitoring guide, migration
  guides, solution database): https://docs.redhat.com/en/
- Ubuntu Server guide (how-to layout per subsystem):
  https://documentation.ubuntu.com/server/
- Debian reference & release notes: https://www.debian.org/doc/ ,
  https://www.debian.org/releases/stable/ , https://wiki.debian.org/
- Fedora docs and change pages (per-release feature changes that break scripts):
  https://docs.fedoraproject.org/ and https://fedoraproject.org/wiki/Changes
- SUSE/SLES: https://documentation.suse.com/
- Arch Wiki (excellent distro-agnostic internals; verify against your distro's defaults):
  https://wiki.archlinux.org/

Performance, tracing, eBPF
- Brendan Gregg (USE method, Linux Performance, flame graphs, eBPF books):
  https://www.brendangregg.com/linuxperf.html , https://www.brendangregg.com/usemethod.html
- bcc tools reference: https://github.com/iovisor/bcc/tree/master/tools
- bpftrace: https://bpftrace.org/ and https://github.com/iovisor/bpftrace
- eBPF ecosystem and features by kernel version: https://ebpf.io/
- iproute2 (source + releases): https://wiki.linuxfoundation.org/networking/iproute2 ,
  https://github.com/iproute2/iproute2
- sysstat (iostat/sar semantics): https://github.com/sysstat/sysstat

Networking
- RFC 791/793/9293 (TCP semantics, why `TIME_WAIT` exists), RFC 1191 & 4821 (PMTUD),
  RFC 6298 (RTO): https://www.rfc-editor.org/
- Netfilter/nftables: https://netfilter.org/ , https://www.nftables.org/
- Wireshark capture/tshark statistics reference: https://www.wireshark.org/docs/

Storage
- kernel docs for ext4, XFS, Btrfs, device-mapper, dm-raid, NVMe:
  https://docs.kernel.org/filesystems/ and https://docs.kernel.org/driver-api/nvme/
- lvm2 docs (`lvm.conf` thin autoextend, `vgcfgrestore`): https://sourceware.org/lvm2/ ,
  `man 5 lvm.conf`
- mdadm: `man 4 md`, https://linuxraid.org/
- SMART attribute semantics: https://smartmontools.sourceforge.io/
- S.M.A.R.T./NVMe health interpretation in vendor docs (drive-specific thresholds).

Security
- MITRE ATT&CK for Linux (persistence, defence evasion, exfiltration techniques):
  https://attack.mitre.org/
- NIST SP 800-61 (computer security incident handling guide):
  https://csrc.nist.gov/pubs/sp/800/61/r2/final
- RFC 3227 — order of volatilities for evidence collection:
  https://www.rfc-editor.org/rfc/rfc3227
- SELinux (Red Hat guide is the best practical treatment):
  https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/ ,
  https://selinuxproject.org/ ; AppArmor: https://apparmor.net/
- Kernel CVE tracking: https://nvd.nist.gov/ , distro security advisories
  (https://security-tracker.debian.org/ , https://ubuntu.com/security/cves ,
  https://access.redhat.com/security/cve/ , https://oracle.com/linux/cve-kernel-advisories.html)
- CISA KEV (known exploited — prioritises patching over CVSS alone):
  https://www.cisa.gov/known-exploited-vulnerabilities-catalog

Shell
- `bash-builtins`, `man 1 bash` (INVOCATION, SETTING, ERR traps, `pipefail` semantics)
- ShellCheck rule index (each code explains the bug class): https://www.shellcheck.net/wiki/
- Wooledge Bash Guide (community-authoritative, correct on quoting/expansion):
  https://mywiki.wooledge.org/BashGuide
- Google Shell Style Guide: https://google.github.io/styleguide/shellguide.html

## 3. Divergence snapshot (dated — re-verify)

Recorded 2026-11-06 from primary sources (kernel.org release table, distro release
notes/announcements, project changelogs). **Point releases and dates move; confirm with
§1 before acting on any line.** The purpose is to tell you *which* assumptions are
currently dangerous, not to replace the docs.

Kernel series and support (kernel.org release table)
- Longterm trees at time of writing: **6.18** and **6.12** (projected EOL Dec 2028),
  **6.6** and **6.1** (Dec 2027), **5.15** and **5.10** (Dec 2026 — refresh now if you
  still run them). Sampled latest point releases: 6.6.161, 6.1.191, 5.15.224, 5.10.273.
- Only important fixes reach longterm trees; distribution kernels are not the same as
  kernel.org trees and vendor kernel support questions belong to the vendor.

Current major releases (as of writing)
| | Stable/LTS at writing | Kernel | Default FS | cgroup | Init | Package mgr | Notes |
|---|---|---|---|---|---|---|---|
| Debian | 13 "trixie" (13.2) | 6.12 | ext4 | v2 | systemd | apt/dpkg | Support ~June 2030. i386 no longer installable (amd64 only for 32-bit userspace); 64-bit `time_t` ABI transition; HTTP network boot |
| Ubuntu | 26.04 LTS "Resolute Raccoon" (released 2026-04-23, ~April 2031 + ESM) | new major in 26.04 | ext4 | **v2 mandatory** | systemd | apt | **cgroup v1 support removed**: hosts booted with v1 are blocked from upgrading; images older than 18.04 unusable (they need v1); Wayland-only desktop |
| RHEL | 10.x (10.2 area), 9.x, 8.x (late maintenance) | 6.12 on RHEL 10 | XFS | v1 **removed** in 10 | systemd | dnf (dnf4 on RHEL 10/CentOS Stream 10) | RHEL 10 also drops Xorg (Wayland only) and network teaming; adds bootc image mode and post-quantum crypto in the TLS stack |
| Fedora | 44 / 45 | rolling per release (~6.17/6.18-era) | Btrfs (Workstation) | v2 | systemd | **dnf5** (default since Fedora 41) | Fedora 45 relocates repo config to `/usr/share/dnf5/repos.d` (keys `/usr/share/pki/rpm-gpg`), so `/etc/yum.repos.d` can be empty; CoreOS/IoT mount `/` via composefs (read-only) |
| openSUSE | Leap / Tumbleweed | varies | Btrfs | v2 | systemd | zypper | Snapper rollback semantics differ by layout |

Other divergences worth knowing right now
- **systemd 259 dropped cgroup v1 support** — tooling and old container runtimes that
  mount v1 hierarchies break on RHEL 10 / Ubuntu 26.04 / systemd-259 hosts.
- **RHEL 9+**: `SELINUX=disabled` in `/etc/selinux/config` is no longer honoured
  (kernel support removed) — disabling needs `selinux=0` on the kernel command line.
  `network-scripts` is gone; NetworkManager is the only supported interface config.
  x86-64-v2 is the minimum CPU baseline (pre-2009 Intel / pre-2011 AMD unsupported).
- **RHEL 10 / CentOS Stream 10 keep dnf4**; Fedora uses dnf5. Repo-add syntax,
  `groupinstall`-style aliases, and plugin behaviour differ — check `dnf --version`
  before copying a command between them.
- **Container networking is nftables-first now**: Podman/Netavark uses nftables by
  default (Fedora update), Docker 29 makes the containerd image store the default for
  fresh installs and adds nftables support. `iptables -L` showing nothing does not mean
  there are no rules — read `nft list ruleset` and `iptables-submit`/legacy backends.
- **iproute2 in the 6.x series** (e.g. `iproute2-6.15`, libbpf 1.5) — `nstat -az`,
  `nstat -s 1`, `ss -tin`, `ip -d` are the modern surface.
- **Fail2ban on Debian 13** defaults to the systemd journal backend and nftables ban
  actions (and Python 3.12) — old `iptables`-based jail examples do not transfer.
- **ZFS 2.4.x**, **Btrfs** as default on Fedora/SUSE/Ubuntu-installed-hosts differ in
  snapshot/rollback tooling (e.g. `snapper rollback` semantics depend on subvolume and
  GRUB layout — test the rollback on a VM before trusting it in an emergency).

## 4. Where upstream truth lives per subsystem

When a claim matters, go to the layer that defines it, not to a summary:

| Question | Go to |
|---|---|
| Does this syscall behave as I think? | `man 2 <call>`, then glibc/kernel source |
| Is this sysctl real and what are its units? | `/proc/sys/…` + `Documentation/admin-guide/sysctl/` (docs.kernel.org) |
| Is this unit directive valid for *this* systemd? | `systemd.directives(7)` for the installed version |
| Is this cgroup file meaningful? | `man 7 cgroups`, kernel `Documentation/admin-guide/cgroup-v2.rst` |
| Which kernel introduced/regressed this? | `git log` on the tree / `lore.kernel.org` search / distro bugzilla |
| Does this distro ship that default? | the distro's release notes + `Changes` pages + package changelog (`rpm --changelog`, `apt-get changelog`) |
| Is this flag real on this build? | `man`, `--help`, `--version`, `-V` (e.g. `nstat -V` prints the iproute2 release) |
| Am I interpreting this metric right? | the tool's own `man` (e.g. `man 8 iostat` documents `%util` and the deprecated `svctm`) |
| Am I allowed to do this to a customer system? | the contract, the change process, and the law — not a blog |

Rule of thumb for citations in answers: name the document and the version
("`man 8 iostat` (sysstat 12.7): `%util` is unreliable for queue-depth > 1 devices"),
so the reader can check you rather than trust you.
