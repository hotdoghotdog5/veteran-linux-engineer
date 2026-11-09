# Toolbox: what proves what

Contents
- [1. Modern vs deprecated (do not reach for the old ones)](#1-modern-vs-deprecated-do-not-reach-for-the-old-ones)
- [2. First-look command set (read-only)](#2-first-look-command-set-read-only)
- [3. Reading the classic tools correctly](#3-reading-the-classic-tools-correctly)
- [4. eBPF (bcc / bpftrace): the right probe for the question](#4-ebpf-bcc--bpftrace-the-right-probe-for-the-question)
- [5. syscalls, tracing, and "why does it do that"](#5-syscalls-tracing-and-why-does-it-do-that)
- [6. Process and file forensics on a live host](#6-process-and-file-forensics-on-a-live-host)
- [7. /proc and /sys: the parts worth memorising](#7-proc-and-sys-the-parts-worth-memorising)
- [8. Network capture and analysis](#8-network-capture-and-analysis)
- [9. Benchmarking and synthetic validation](#9-benchmarking-and-synthetic-validation)
- [10. Shell and text-processing craft](#10-shell-and-text-processing-craft)
- [11. Installing the right diagnostic package](#11-installing-the-right-diagnostic-package)
- [Sources](#sources)

## 1. Modern vs deprecated (do not reach for the old ones)

| Old (often absent) | Use instead | Notes |
|---|---|---|
| `ifconfig` | `ip -br a`, `ip a`, `ip link set` | `net-tools` not installed on minimal/Ubuntu 24+/RHEL 9/10 images |
| `netstat` | `ss -tulpn`, `ss -s`, `ss -ti` | `ss` also shows timers/retrans; `netstat` missing by default |
| `route` | `ip route`, `ip rule`, `ip neigh` | policy routing is invisible without `ip rule` |
| `arp` | `ip neigh` | |
| `bridge`/`brctl` | `bridge link`, `bridge fdb` | |
| `ethtool -S` grep by hand | `ethtool -S` + `nstat -s 1` deltas | counters only mean something as deltas |
| `iptables` | `nft list ruleset` (`iptables-nft` is a frontend) | legacy `iptables` backend is gone/legacy on most distros |
| `service X restart` | `systemctl restart X` | shim hides unit failures |
| `chkconfig` | `systemctl is-enabled` / `enable --now` | |
| `ntpd`/`ntpstat` | `chronyc tracking`, `timedatectl` | ntpd retired |
| `mcelog` | `rasdaemon` + `ras-mc-ctl` | mcelog Intel-focused, superseded |
| `yum` | `dnf` (dnf5 on Fedora 41+; dnf4 on RHEL 10/CentOS Stream 10) | subcommand syntax differs |
| `tcpdump` for app-level triage | `ss -ti`, `nstat`, `tshark`/`tcpdump -w` then analyze | live parsing on a busy link drops packets |
| `dmesg` alone | `journalctl -k -b -1` (durable) | ring buffer is fixed-size and volatile |
| `free -m` "used" | `free -h` `available`, `/proc/meminfo` `MemAvailable` | cache is reclaimable |
| `ps aux \| grep x` | `pgrep -af x`, `pidof`, `systemctl status` | excludes the grep itself |
| `killall`/`pkill` blind | `pgrep -af` first, then signal the PID | pattern matched against full cmdline |

## 2. First-look command set (read-only)

The 60-second health sweep (Gregg's breakdown, adapted). Each line names what it rules
in or out:

```sh
uptime                     # load trend + how long since boot (unexpected reboot?)
dmesg -T | tail -30        # kernel: OOM, IO errors, link flap, drivers, hardware
journalctl -p err -b --no-pager | tail -30   # services that complained this boot
vmstat 1 5                 # r/b (CPU/IO blocked), si/so (memory), wa, cs
mpstat -P ALL 1 3          # per-cpu balance, %usr/%sys/%irq/%idle
pidstat 1 5                # per-process CPU; add -d for IO, -w for context switches
iostat -xz 1 4             # device latency/queue (skip first sample)
sar -n DEV 1 3             # NIC throughput/packets; sar -n TCP,ETCP 1 3 for errors
sar -B 1 3 ; sar -r 1 3    # paging + memory
top -bn1 | head -25        # who; then press 1 (cpus), H (threads), < (fields)
df -hT; df -i; free -h     # space, inodes, memory
ps -eo pid,stat,wchan:24,cmd | awk '$2 ~ /D/ | $2 ~ /Z/'   # stuck + zombies
ss -s; ss -ltnp            # socket census + listeners
cat /proc/pressure/*       # PSI cpu/memory/io: some/full
systemctl --failed         # systemd's own opinion
```
Run it and *write the numbers down*. That is your baseline, and it is what makes the
rest of the investigation a comparison instead of a story.

## 3. Reading the classic tools correctly

**`vmstat 1 5`** — skip first line. `r` > cores = CPU saturation. `b` > 0 sustained =
blocked on I/O. `si`/`so` non-zero sustained = memory pressure (thrashing), and a
high `si` with low `so` can mean someone is `madvise`ing or a tmpfs is being paged.
`cs` in the hundreds of thousands = lock contention or chatty IPC. `wa` is *idle while
waiting* — high `wa` with low `r` means one slow synchronous path, not a busy machine.

**`mpstat -P ALL 1`** — look for skew: one core at 100% (`%irq`/`%soft` → interrupt
affinity or single-queue NIC), or all cores at 40% with high `%sys` (syscall/lock storm).
`%guest` high = your VM's neighbour. `%steal` non-zero = hypervisor oversubscribed: the
fix is not in this guest.

**`iostat -xz 1`** — skip first sample (since-boot averages). Judge: `r_await`/`w_await`
against the device's own normal, `aqu-sz` > ~1 for HDD / >>1 for SSD means a real queue,
`%util` only for spinning rust. `%rrqm`/`%wrqm` show merging (low merging on random
workload is normal). `rareq-sz`/`wareq-sz` shape the diagnosis.
Baselines: HDD 5–15 ms, SATA SSD 0.05–0.5 ms, NVMe 0.01–0.03 ms; cloud volumes throttle
→ check provider metrics for burst/IOPS credits.

**`top`/`ps`** — `%CPU` > 100 means multi-threaded (top's Irix mode); switch to Solaris
mode (`I`) to divide by cores. `D` = uninterruptible (blocked; cannot be killed — the
underlying operation must complete or time out). `Z` = zombie: the parent is not
reaping; you cannot kill a zombie, fix or restart the parent. `R` with high `ni` =
nice-level starvation. `ps -eLo pid,tid,stat,pcpu` for thread-level;
`ps -o pid,nlwp` for thread counts (a thread leak looks like memory pressure via
stack VSS).

**`sar`** — the only tool that answers "what was happening at 03:12" after the fact
(`sysstat` collects via cron/systemd timer; verify it is enabled *before* you need it):
`sar -u -f /var/log/sa/saDD -s 03:00:00 -e 03:30:00`, `sar -d`, `sar -n DEV`, `sar -r`.
If `sar` has no data, that is itself a finding: enable it.

**`ss`** — `ss -ltnp` (`Recv-Q` on a listener = accept queue depth, `Send-Q` = backlog
max → `ListenOverflows`), `ss -ti dst <peer>` per-flow `rtt`, `retrans`, `cwnd`,
`pacing_rate`, `notsent`, `rcv_space`; `ss -s` census; `ss -K` to kill a socket
(Class B — last-resort). `ss -m` for memory.

**`nstat`** — cumulative since boot (`nstat -az`); `nstat` with no args prints deltas
since the previous `nstat` run, which is the correct way to read counters;
`nstat -s 1` samples. Only rising counters during the failure window matter.

**`lsof`** — `+L1` deleted-but-open; `-p`, `+D`, `-i :443`, `-u <user>`; slow on big
boxes (it stats everything) — prefer `find /proc/*/fd -lname '/path (deleted)'` when
you need speed.

## 4. eBPF (bcc / bpftrace): the right probe for the question

Prebuilt tools answer most production questions; write a probe only as a last resort.
Overhead guidance from field practice: `execsnoop`, `opensnoop`, `biolatency`,
`tcplife`, `tcpretrans` are cheap enough to leave running; `runqlat`, `profile`,
`offcputime` and anything sampling stacks should run for 10–60 s then stop.

| Question | Tool |
|---|---|
| Which disk latency, and its distribution | `biolatency [1 10]`, `biosnoop`, `bpftrace block:rq_complete` |
| Which process is doing the I/O | `biotop`, `biosnoop`, `pidstat -d` |
| Slow filesystem calls | `ext4slower`/`xfsslower`, `fsslower` |
| Who opened/deleted this file | `opensnoop -n <name>`, `namesnoop`, `bitesize` |
| What just started/exited (short-lived procs) | `execsnoop`, `capable`, `undumpable` |
| Where did the CPU time go | `profile 99 -p <pid>` + flamegraph.pl, `perf record -F 99 -g` |
| Off-CPU (blocked) time and why | `offcputime 30 -p <pid>`, `offwaketime`, `waittime` |
| Run-queue / scheduling latency | `runqlat`, `runqlen`, `schedsnoop` |
| TCP connection lifecycle + latency | `tcpconnect`, `tcplife`, `tcpretrans`, `tcptop`, `tcptracer` |
| DNS query latency | `gethostlatency` |
| Syscall latency/counts | `bpftrace -e 'tracepoint:raw_syscalls:sys_exit{@[comm]=count()}'`, `setsnoop` |
| Lock/futex contention | `bpftrace futex`, `perf lock`, `offcputime` |
| OOM/throttle events as they happen | `oomkill` (bcc), `bpftrace kprobe:oom_kill_process` |
| Packet drop location | `dropwatch -l kas`, `xdpdrop`, `tcplife` |

```sh
bpftrace -e 'kprobe:vfs_read /comm=="app"/ {@[pid,stack(3)] = count(); }'   # why is it reading
bpftrace -e 'tracepoint:sched:sched_switch /args->prev_state=="TASK_UNINTERRUPTIBLE"/
             { @[kstack] = count(); }'                                      # D-state cause
bpftrace -e 'interval:s:5 { exit(); } kprobe:oom_kill_process { printf("OOM %s\n", comm); }'
bcc/offcputime -p $(pgrep -f app) 30 > off.stacks; ./flamegraph.pl --title "offcpu" < off.stacks > off.svg
```
Prereqs: kernel ≥ 4.9-ish for bcc (newer for CO-RE), `BTF` at
`/sys/kernel/btf/vmlinux` for bpftrace CO-RE, `debugfs`/`bpffs` mounted, `bpf`
capability or `CAP_BPF`+`CAP_PERFMON` (or run as root), `kernel-devel`/headers on some
distros, Secure Boot may block the module. `bpftool probe`, `bpftool prog list`,
`bpftool btf dump file /sys/kernel/btf/vmlinux format c` for debugging. **Always detach
what you attach** — check `bpftool prog list` before you walk away, and never leave a
`profile`-rate probe on a hot database.

## 5. syscalls, tracing, and "why does it do that"

```sh
strace -f -tt -T -s 200 -e trace=network,file,process -p <pid>   # -T = time in syscall
strace -f -e trace=all -o /tmp/s.txt -p <pid> ; strace -c -p <pid>   # -c = summary counts
ltrace -p <pid>                                    # library calls (rarely needed)
cat /proc/<pid>/stack                          # kernel stack of a blocked task (root)
gdb -p <pid> -batch -ex 'thread apply all bt'  # live userspace stacks (pauses the process)
perf trace -p <pid>                              # lower-overhead syscall view
```
Reading `strace`: `-T` shows the syscall duration — one line at 1200 ms localizes the
stall instantly. `ENOENT` storms on paths = a search-order problem (config, loader,
`LD_LIBRARY_PATH`, plugin scan). `EAGAIN` on a non-blocking socket is normal. `EACCES`
vs `EPERM` are *different* failures (permission bits/MAC vs capability/privilege) and
point at different fixes. `ECONNREFUSED` vs `ETIMEDOUT` vs `ENETUNREACH` vs `EHOSTUNREACH`
name the layer that failed. `-f` follows children (a wrapper script without it is
useless). Overhead is significant on high-frequency syscall paths: use `-c`, `-e`
filters, or bpftrace instead; never leave `strace -p` attached to production.

## 6. Process and file forensics on a live host

```sh
ls -la /proc/<pid>/                        # full state of a process
readlink /proc/<pid>/{cwd,exe,root}        # deleted binary still running? (… (deleted))
cat /proc/<pid>/cmdline | tr '\0' ' '; echo
cat /proc/<pid>/status | egrep 'State|Threads|VmRSS|Uid|Gid|PPid'
cat /proc/<pid>/io /proc/<pid>/sched /proc/<pid>/wchan /proc/<pid>/limits
cat /proc/<pid>/cgroup                     # which slice/container owns it
cat /proc/<pid>/smaps_rollup               # real memory incl. shared/PSS
ls -l /proc/<pid>/fd | wc -l               # FD use vs its LimitNOFILE
gcore -o /tmp/core.<pid> <pid>             # snapshot memory before it dies (big: check space)
stat -c '%n m=%y c=%z a=%y' <files>        # mtime/ctime/atime — ctime proves the change
find /etc /var/www /home -xdev -newerct '-2 hours' -printf '%c %p\n'   # changed recently
getfattr -d -m - <path>                    # SELinux/ACL xattrs; also `ls -Z`, `namei -l`
ls -la $(dirname <path>)                   # directory perms: namei -l /a/b/c for the full path
```
A "file I deleted is still growing" is a deleted-but-open fd: `ls -l /proc/<pid>/fd | grep
deleted`, then `: > /proc/<pid>/fd/N` or restart the writer. A process that "disappears"
is usually a short-lived exec (`execsnoop`), a kill from `systemd-oomd`/kernel OOM
(`journalctl -k`), or a `KillMode=control-group` from a unit stop.

## 7. /proc and /sys: the parts worth memorising

```
/proc/meminfo        MemAvailable, CommitLimit, Committed_AS, Dirty, Writeback, Slab
/proc/loadavg        runnable+D avg, running/total, last pid
/proc/pressure/{cpu,memory,io}     some/full avg10,60,300 total  (PSI, >=4.20)
/proc/<pid>/{smaps_rollup,io,stack,cgroup,fd,limits,environ}
/proc/sys/vm/*       swappiness overcommit_memory dirty_ratio min_free_kbytes vfs_cache_pressure
/proc/sys/net/ipv4/* tcp_* ip_* conntrack_*  (see sysctl.d for the persistent form)
/proc/net/{dev,tcp,snmp,sockstat,netstat}    raw sources for ss/netstat
/proc/fs/ext4/<dev>/options                  effective mount options, live
/proc/mounts vs `findmnt`                    kernel truth vs decorated view
/sys/block/<dev>/queue/*                     rotational, nr_requests, scheduler, read_ahead_kb
/sys/block/<dev>/stat                        raw block counters (source of iostat)
/sys/class/net/<if>/statistics/*             rx/tx packets, bytes, dropped, errors
/sys/fs/cgroup/<path>/{cpu.max,cpu.stat,memory.max,memory.current,memory.events,io.stat,pids.max}
/sys/devices/system/edac/mc/mc*/{ce_count,ue_count}     memory CE/UE totals
/sys/module/<mod>/{srcversion,parameters,taint}
/sys/kernel/debug/…                          debugfs (needs `mount -t debugfs`)
/sys/devices/system/node/node*/meminfo         per-NUMA memory (numastat -m)
/sys/devices/system/cpu/cpu*/cpufreq/…         frequency governor + actual Hz
/sys/power/…  /sys/class/thermal/…             suspend state, thermal zones
```
`/proc`/`/sys` values are *instantaneous*; read them repeatedly (`watch -d -n1`,
`pv`, or a loop) or you will mistake a sample for a trend. `sysctl -a` output is not
the persistent config — persistence lives in `/etc/sysctl.d/*.conf`,
`/run/sysctl.d/*.conf`, `/usr/lib/sysctl.d/*.conf` applied in that order, last match
wins, so a vendor file in `/usr/lib` can be overridden by your `/etc` file and by
anything in `/run`. `systemd-sysctl.service` applies them at boot; `sysctl --load`
re-applies; a runtime `sysctl -w` is gone on reboot.

## 8. Network capture and analysis

```sh
# On-host, cheap first: does the packet arrive, and what does the kernel say?
nstat -s 1 ; ss -tin ; ethtool -S <if> | grep -Ei 'drop|err'
sudo tcpdump -ni <if> -c 200 'host <peer> and port <p>'          # live, small
sudo tcpdump -Q in -ni <if> 'tcp[tcpflags] & (tcp-syn|tcp-rst) != 0' -c 100
sudo timeout 60 tcpdump -ni <if> 'port 443 and greater 100' -w /tmp/a.pcap \
     && wireshark /tmp/a.pcap
tshark -r /tmp/a.pcap -q -z io,stat,1 -z conv,tcp -z tcp,analysis
ss -i dst <peer> ; bcc/tcplife ; bcc/tcpretrans -t            # non-capture alternative
```
Capture rules: always bound (`-c`, `timeout`, `-C`/`-G` rotation, a BPF filter) — an
unfiltered capture on a busy link becomes a disk and CPU incident of its own. Write to
`-w` and analyze offline rather than parsing live. Capture on *both* ends when the
story disagrees (`-Q in`/`-Q out` and mirrored port or `tc sample`). Filter for what
you are testing, not "everything on the host". On `veth`/bridge/OVS setups pick the
right interface (`ip -d link` for the encap), and remember offload (TSO/GRO) makes
captures look like impossibly large segments — disable offload temporarily only on a
test box (`ethtool -K`).

## 9. Benchmarking and synthetic validation

Validate a hypothesis or a change with a controlled load, never with production traffic
alone. `fio` with the workload's real pattern (bs, iodepth, rw, fsync, direct=1 vs
buffered) and `--lat-log`; `--readonly`/`size=` guards so the test does not destroy
data; test on an unmounted LV or a scratch file, not the live database directory.
`iperf3 -M`/`-P` for TCP throughput (mind single-stream limits vs parallel),
`qperf`/`netperf` for latency, `wrk`/`hey`/`vegeta` for HTTP, `stress-ng --vm/--cpu/--iomix`
to reproduce a resource condition deliberately in a VM. Cross-check every synthetic
result against one real metric from production — synthetic numbers that do not
reproduce the observed failure are describing a different problem.

## 10. Shell and text-processing craft

```sh
set -Eeuo pipefail                 # E = ERR trap in functions; e, u, o pipefail
trap 'rc=$?; echo "line $LINENO: $BASH_COMMAND -> $rc" >&2' ERR
trap cleanup EXIT                  # cleanup only on the paths that need it
```
- Quote every expansion: `"$x"`, `"$(cmd)"`, `"${arr[@]}"`, `"${arr[*]}"`. Unquoted is
  word-split + glob-expanded and is the single largest bash bug class (shellcheck
  SC2086). Test with `find . -name '* *'`-style hostile names.
- Build commands in arrays: `cmd=( grep -F -- "$pat" "$file" ); "${cmd[@]}"`. Never
  store a command in a string.
- `printf '%s\n'` over `echo`; `echo`'s flag handling is not portable (`echo -n`,
  `echo -e`, and `$x` starting with `-`).
- `pipefail` + `head` = exit 141 (SIGPIPE). Guard: `cmd | head -n 20 || true`, or
  `sed -n '1,20p'`.
- `find -print0 | while IFS= read -r -d '' f` or `xargs -0`; never `ls`-parsed loops.
  `find -xdev` to stay on one filesystem; `-delete` last after a dry run.
- `local`/`declare` separate assignment from command substitution or `$?` is masked;
  `set -e` does not fire on `cmd || true`, on `if` conditions, or on the last command of
  a pipeline in a subshell — know the exceptions or your "safety" flag becomes silence.
- Subshells lose variables: `x=1; ( x=2 ); echo $x` → 1; `while read` in a pipe runs in
  a subshell → use `while ... done < <(cmd)` or `mapfile`.
- Signal/exit semantics: 126 unpermitted, 127 not found, 128+n signal n (137=SIGKILL,
  143=SIGTERM, 141=SIGPIPE), 255 exit-out-of-range/ssh error. `kill -TERM` before
  `kill -KILL`, with a wait; `timeout 30s cmd` instead of hand-rolled watchdogs.
- Portability across GNU/BSD (macOS) and shells: `sed -i` needs an arg on BSD,
  `date -d` vs `date -v`, `stat -c` vs `stat -f`, `readlink -f` (use `realpath`),
  `$'...'` quoting, arrays/`[[`/`mapfile` need bash (macOS ships 3.2 — `bash4` or
  avoid). `sort -V` for versions, `awk` (`gawk` vs `mawk`: no `gensub`, no `asort`).
  Detect rather than assume: `sed --version 2>/dev/null | grep -q GNU`.
- `shellcheck` every script you generate before running it. Anything past ~100 lines of
  bash wants a real language (python3 is on every server) with proper error handling.
- `PATH` in cron/systemd is minimal: absolute paths or an explicit `PATH=` in the unit
  or crontab; environment from a login shell is *not* what a unit sees.

## 11. Installing the right diagnostic package

Names differ by distro family (verify with the distro's package search before
recommending): `sysstat` (sar/iostat/pidstat/mpstat), `iproute2` (ip/ss/nstat/tc),
`util-linux` (lsblk/findmnt/blkid), `procps-ng` (ps/free/vmstat), `lsof`, `pciutils`
(lspci), `usbutils`, `dmidecode`, `smartmontools`, `nvme-cli`, `ethtool`, `lm-sensors`,
`rasdaemon`, `ipmitool`, `tcpdump`/`tshark`/`wireshark-cli`, `bind-utils`/`dnsutils`
(dig/nslookup), `iputils` (ping/arping), `fio`, `iperf3`, `stress-ng`, `bpftrace`,
`bcc-tools` vs `bpfcc-tools` (Debian/Ubuntu names them `-bpfcc`),
`linux-tools-common`/`linux-tools-$(uname -r)` for `perf`, `python3-perf`, `perf-tools`,
`net-tools` (deliberately absent), `sos` (sosreport) / `must-gather`, `kexec-tools`
vs `kdump-tools`, `strace`/`ltrace`, `gdb`, `drgn`, `crash`, `e2fsprogs`, `xfsprogs`,
`btrfs-progs`, `mdadm`, `lvm2`, `nftables`, `jq`, `python3`. Prefer the distro package
over anything downloaded and piped to a shell; if a vendor tool is required, verify its
checksum/signature and install from a repository.

## Sources

- Brendan Gregg — USE method and Linux Performance tool catalogue:
  https://www.brendangregg.com/usemethod.html , https://www.brendangregg.com/linuxperf.html ;
  bcc tool list and overhead guidance: https://github.com/iovisor/bcc/blob/master/tools/
- `man` info pages for the installed version (`man 8 iostat`, `man 8 ss`, `man 8 nstat`,
  `man 5 sysctl.d`, `man 7 cgroups`, `man 7 proc`, `man 5 systemd.unit`):
  https://man7.org/linux/man-pages/
- kernel docs (PSI, ext4, scheduling, sysctl, dm/raid): https://docs.kernel.org/
- iproute2 sources and release notes: https://github.com/iproute2/iproute2
- shellcheck rules (SC2086 and friends): https://www.shellcheck.net/wiki/
- iostat/sysstat column semantics: https://github.com/sysstat/sysstat (plus
  `man 8 iostat` — `svctm` is deprecated/unreliable; `%util` caveats are documented there)
