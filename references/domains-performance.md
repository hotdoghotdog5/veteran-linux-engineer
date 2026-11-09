# Subsystems field guide: compute and storage

CPU scheduling, memory and OOM, block I/O latency, filesystems and ENOSPC, LVM and md/DM, NFS and FUSE.

Contents
- [1. CPU and scheduling](#1-cpu-and-scheduling)
- [2. Memory and OOM](#2-memory-and-oom)
- [3. Storage: block layer, I/O latency](#3-storage-block-layer-io-latency)
- [4. Filesystems and ENOSPC](#4-filesystems-and-enospc)
- [5. LVM and md/DM](#5-lvm-and-mddm)
- [6. NFS, FUSE, and network filesystems](#6-nfs-fuse-and-network-filesystems)

## 1. CPU and scheduling

**Meaning of the numbers.** Linux load average counts tasks that are runnable *and*
tasks in uninterruptible sleep (`D`, typically blocked on storage or a kernel lock), so
"load 40" can coexist with idle CPUs. It is a 1/5/15-minute exponentially damped
average of that count — compare it to `nproc`, and always split runnable vs blocked.
`/proc/loadavg` is **not namespaced**: inside a container it reports the whole host.

```sh
vmstat 1 5                      # r = runnable, b = blocked uninterruptible, wa = iowait
mpstat -P ALL 1 3               # per-cpu skew: one hot core != a busy machine
pidstat 1 5                     # per-process on-CPU
ps -eo pid,stat,wchan:28,cmd | awk '$2 ~ /^D/'   # what is blocked, and where
cat /proc/pressure/{cpu,memory,io}               # PSI: some/full avg10 avg60 avg300
perf top                        # on-CPU hotspots (moderate overhead: use briefly)
offcputime-bpfcc 30 / bpftrace offcpu patterns   # where time is *waiting*
```

**Saturation.** PSI `some` = share of time at least one task stalled on the resource;
`full` = time *all* non-idle tasks were stalled. Sustained `full` in the tens of
percent is thrashing, not noise; single spikes are usually nothing. Read avg10/60/300
together. CPU saturation: `vmstat r` > cores, `schedstat` wait, `perf sched`, and for
cgroups `cpu.stat` → `nr_throttled`/`throttled_time`.

**Throttling that looks like slowness.** A container or slice can be CPU-throttled with
the host nearly idle. Read the cgroup, not the host:
`/sys/fs/cgroup/<path>/cpu.max` (`quota period`, e.g. `200000 100000` = 2 cores) and
`cpu.stat`. Kubernetes CPU limits are enforced by cgroup throttling, so a pod can be
slow on an empty node. Throttling shows up as latency with flat CPU utilization — the
signature people misdiagnose as "network".

**Other CPU surprises.** Frequency/IdleStates: `turbostat`, `cpupower frequency-info`,
governor (`schedutil`/`powersave`), thermal throttling (`/sys/class/thermal`,
`journalctl -k | grep -i thrott`); CPU affinity/`taskset`; `nohz_full`/isolcpus for
latency-sensitive work; cgroup `cpu.weight`; hyperthread contention (schedulers count
siblings as run-locations — sibling noise shows as low IPC: `perf stat`); RT priority
`SCHED_FIFO` starving normal work; and `nice` only matters under contention.

## 2. Memory and OOM

**Read the accounting correctly.** `free -h` "available" ≈ `MemAvailable` (kernel
≥3.14) and is the number that matters; page cache is reclaimable, so "used" in the
`used` column is not a crisis. Modern kernels with MGLRU (≥6.1) reclaim differently;
`min_free_kbytes`, `watermark_scale_factor`, and `zone_reclaim_mode` matter more than
`swappiness` on many boxes. Fragmentation: `/proc/buddyinfo`,
`/sys/kernel/debug/extfrag/unusable_index` (debugfs).

```sh
cat /proc/pressure/memory                 # some/full — leading indicator, use this
vmstat 1 5                                # si/so sustained = thrashing
sar -B 1 5                                # pgscan/pgfaultmaj: reclaim work
sar -r 1 5 ; sar -S 1 5                   # memory + swap in/out
ps -eo pid,comm,rss,vsz --sort=-rss | head
cat /proc/meminfo | egrep 'MemAvailable|CommitLimit|Committed_AS|Dirty|Writeback|SwapTotal|SwapFree|Slab|SReclaimable'
slabtop -o | head                         # dentry/inode cache blowups
```

**Overcommit.** `vm.overcommit_memory=0` heuristic, `1` always allow, `2` strict
against `CommitLimit`. Under `1` you get OOM kills instead of allocation failure —
common on Redis/JVM shops and often deliberate. Check `Committed_AS` vs `CommitLimit`
before concluding mode 2 is "safer"; neither mode is universally right.

**OOM event forensics.** The kernel kills when allocation fails *while reclaiming*, so
by then the box is already thrashing. Find the event and the victim:

```sh
journalctl -k -b | grep -iE 'out of memory|oom-kill|killed process'
dmesg -T | grep -iE 'oom'          # victim, oom_score_adj, task list (needs vm.oom_dump_tasks=1)
cat /proc/<pid>/oom_score /proc/<pid>/oom_score_adj
```
The dump names `constraint` (`NONE`/`MEMORY_POLICY`/`MEMCG`), which tells you host-wide
vs cgroup OOM — a different investigation each time.

**Prevention that actually works.**
- cgroup v2: `MemoryHigh` (throttles reclaim pressure) and `MemoryMax` (hard) on the
  unit or slice; `memory.oom.group` semantics must agree with the runtime.
- Userspace watchers kill *before* the kernel does: `earlyoom` (thresholds on
  `MemAvailable`/swap, default ~10%/5%, SIGTERM then SIGKILL; percentage-based so it
  fires very early on huge boxes — tune `-m`), `nohang`, or `systemd-oomd`
  (PSI-based, cgroup v2 + PSI required). Choose one; more than one is a fight.
- `oom_score_adj`: give important daemons a *mild* negative value. `-1000` removes the
  process from consideration entirely and guarantees someone else dies.
- Java/Node/Python must see the cgroup limit (recent JVMs do by default; verify with
  `-XX:+UseContainerSupport` behaviour and `MaxRAMPercentage`).
- `zram` for compressed RAM swap on small/RAM-tight hosts; `zswap` for frontswap over
  real swap. Swap on NVMe is cheap insurance; `vm.swappiness=1` is usually wrong because
  it also disables readahead usefulness.

## 3. Storage: block layer, I/O latency

```sh
lsblk -S; lsblk -o NAME,MODEL,ROTA,SIZE,TYPE,MOUNTPOINTS   # rota=1 → spinning
iostat -x 2 5                      # IGNORE first sample: averages since boot
pidstat -d 1 5 ; iotop -oPa        # which process (needs root to see all)
bpftrace -e 'block:rq_complete:{@=hist(nsec-@start)}'      # or biolatency 1 10
blktrace/biotop (bcc)              # per-process block latency
nvme smart-log /dev/nvme0 ; smartctl -a /dev/sdX           # device health
cat /sys/block/nvme0n1/queue/{rotational,nr_requests,scheduler}
```

**Reading `iostat -x` (get this right or you will chase ghosts).** Skip the first
sample. Judge saturation from `aqu-sz` (average queue length) plus latency, not
`%util`. `%util` is "device had at least one request in flight" — 100% on an SSD/NVMe
that is serving 32+ queues in parallel means nothing. Latency baselines (device-side
service incl. queue wait): HDD ~5–15 ms, SATA SSD ~0.05–0.5 ms, NVMe ~0.01–0.03 ms;
cloud volumes throttle instead of saturating, so read the provider's IOPS/throughput
metrics too. `r/s`,`w/s`,`rareq-sz`,`wareq-sz` tell you the *shape*: many small sync
writes vs a few big sequential ones have opposite fixes. `rrqm/s`/`%rrqm` low on random
read patterns is expected; watch `w_await` ≫ `r_await` for writeback pressure.

**Prove it is the disk before touching disk knobs.** `biosnoop`/`biolatency` shows the
latency distribution; if the application's latency matches the device's `await`, the
device is on the path. If device latency is flat and the app is slow, the queue is
elsewhere (lock, CPU throttling, network, dependency).

**Writeback.** Dirty thresholds in `/proc/sys/vm/`: `dirty_ratio`,
`dirty_background_ratio` (percent of node), and the byte-based
`dirty_bytes`/`dirty_background_bytes` which are more predictable on big RAM. `Dirty`
and `Writeback` in meminfo plus `vmstat bo` show flush storms; ext4 journal and
`fsync`-heavy apps (databases) produce periodic spikes that look like device failure.
`fsync` latency ≠ write latency — measure with `fio` using the workload's actual
`fsync` pattern and `--end_fsync`.

**Schedulers/queues.** `mq-deadline`/`kyber`/`bfq`/`none`; `none` is right for NVMe;
`bfq` helps desktop-ish interleaving. Read-ahead (`block/<dev>/queue/read_ahead_kb`)
helps sequential scans and hurts random. Cloud: NVMe multipath vs device-mapper
multipath are different layers — check `nvme list`, `dmsetup ls`, `multipath -ll`.

## 4. Filesystems and ENOSPC

**"No space left on device" taxonomy** — run all four, in this order:

```sh
df -h ; df -i ; findmnt -t tmpfs,devtmpfs,overlay   # blocks, inodes, tmpfs/overlay
lsof +L1                                             # deleted-but-open (df≠du)
tune2fs -l /dev/<dev> | egrep 'Reserved|Free blocks|Filesystem flags|error'
repquota -a 2>/dev/null                              # user/project quotas
```
- `df -h` full but `du` small → a process holds a deleted file (usually a log). Fix by
  truncating the fd (`: > /proc/<pid>/fd/<n>`) or restarting the writer; do not `rm`
  again, it will not free anything.
- `df -h` shows free space but writes fail → inode exhaustion (`df -i`; find the
  directory of millions of small files: `for d in /*; do sudo find "$d" -xdev | wc -l; done`
  or `du --inodes -x -d1`), or ext4's 5% root reserve (non-root gets ENOSPC at ~95%;
  inspect/adjust with `tune2fs -m <pct>`, and reconsider before zeroing it on data
  volumes), or quota, or a full `tmpfs`/`/dev/shm`, or an overlay upperdir full.
- Filesystem went read-only: the kernel did it after an error. `dmesg -T | tail -60`
  first, then `mount | grep ' ('` for `ro,`. ext4 `errors=remount-ro` is the default;
  XFS goes read-only on metadata corruption and often cannot be repaired online —
  `xfs_repair` offline, and check the log state first. **Never fsck a mounted
  filesystem.** Take a filesystem-level backup (or image the block device) before any
  repair tool, and record the exact error strings — they name the subsystem that
  upstream will ask for.
- Grow before you repair: a full filesystem can fail its own repair for lack of space;
  `lvextend -r` (ext4 online grow) or XFS `xfs_growfs` after extending the LV.

**Consistency/repair notes.** ext4: `fsck.ext4 -n` for a read-only look before `-y`;
`e2image` a superblock/image first; `tune2fs -l` for error counts and last check;
`/proc/fs/ext4/<dev>/options` for live mount options. XFS: `xfs_repair -n` dry run,
`xfs_metadump` to share a scrubable image without user data, `xfs_info`, `xfs_db`.
Btrfs: `btrfs device stats`, `btrfs filesystem show`, `btrfs scrub status`, repair
subvolume-by-subvolume and treat `btrfs check --repair` as last resort with vendor
sign-off. ZFS: `zpool status -x`, `zpool get all`, ARC vs `arcstat.py`, dataset quotas
and `refquota`.
Mount option traps: `noatime` vs `relatime`, `nodiratime`, `barrier=0` (data-loss risk,
never on battery-backed-less storage without a decision record), `discard` online TRIM
vs `fstrim.timer` (prefer the timer), `commit=` intervals, `nofail` in fstab for
removable/NFS so boot does not hang.

**fstab discipline.** Always UUID/PARTUUID (`blkid`), never `/dev/sdX` (enumeration is
not stable), always a `nofail`+`timeout` thought for network mounts, and
`systemctl daemon-reload` after editing, then `findmnt` to prove the effective options.

## 5. LVM and md/DM

```sh
pvs; vgs; lvs -a -o +devices,seg_monitor,origin,cow_size     # topology + thin/snap state
lvs --segments ; pvdisplay -m ; vgdisplay --config 'global{obtain_device_list_from_pvmask=0}'
dmsetup ls --tree ; blkmapset show 2>/dev/null
mdadm --detail /dev/mdX ; cat /proc/mdstat ; cat /etc/mdadm.conf 2>/dev/null || ls /etc/mdadm.conf.d
dmesg -T | egrep 'I/O error|blk_update_request|Buffer I/O error|medium|reset'
```

**LVM facts that save recoveries.** VG metadata is auto-backed up: `/etc/lvm/backup/<vg>`
(latest) and `/etc/lvm/archive/<vg>_NNNNN.vg` (every change). `vgcfgrestore --list <vg>`
then restore from there *before* any destructive attempt — and know it restores the
**metadata only**, never LV contents; thin-pool metadata has separate recovery rules.
Copy the backup off-host before restoring.
- Thin pool data full → all writes in the pool fail; extend the pool data LV
  (`lvextend -L +50G vg/pool00`). Thin pool **metadata** full is much worse: the pool
  effectively locks up; `lvextend --poolmetadatasize +4G vg/pool_tmeta` (may need
  `lvextend --poolmetadatasize` on the pool, sometimes with the pool inactive). Set
  `thin_pool_autoextend_threshold`/`percent` in `lvm.conf` *after* the incident so it
  cannot recur, and monitor `data_percent`/`metadata_percent` explicitly.
- Traditional COW snapshots become **invalid** when full; thin snapshots block writes to
  the whole pool. Either delete or extend — decide which before you act.
- `lvextend -r` resizes the FS in one step (ext4; XFS needs `xfs_growfs` after).
  Shrinking XFS is impossible — snapshot before you attempt anything on XFS.
- `pvmove` is long, interruptible-but-awkward, and needs free space elsewhere; check
  `lvs -a` for the mirror/raid type, ensure a metadata backup, and expect the pool to be
  slow while it runs.
- After replacing a disk: `pvcreate`/`vgextend`/`pvmove`/`vgreduce --removemissing`
  (with `--force` only after you accept losing the missing LVs).
- Filter mistakes in `lvm.conf` hide devices: `lvm lvs --config 'log{verbose=1}'` or
  check `global_filter`/`devicesfile` (newer LVM moved device configuration to
  `/etc/lvm/devices/system.devices` — check before blaming the disk).

**md/RAID.** Record the layout before touching it: `mdadm --examine /dev/sdX` per member
and `mdadm --detail /dev/mdX`; dump partition tables (`sfdisk -d /dev/sdX > sdX.pt`) and
superblocks (`mdadm --examine --scan > /root/mdadm.conf.snapshot`). If an array will not
assemble, **image the members first**, then `mdadm --assemble --readonly` against the
images so no write reaches an original. For a degraded array, check which device and
why (`dmesg`, SMART, `mdadm --manage --re-add`) before a rebuild; a rebuild on a
dying second member is how a single disk failure becomes two. `mdadm --grow`/reshape
must be preceded by a real backup — reshape is the most destructive LVM-free operation
in common use. Set/verify `MAILADDR` or a monitoring hook: silent degradation is the
normal failure mode.
Write-intent bitmap speeds resync; `idle` vs `check` actions in `/sys/block/mdX/md/`
let you schedule scrubs rather than discover corruption.

## 6. NFS, FUSE, and network filesystems

**Load spikes and `D` states from NFS.** Look for `D`-state processes stuck in
`nfs_*`/`rpc_*` wait channels. `showmount -e <server>`, `rpcdebug`, `nfsstat -c` /
`-s` (retrans, badcalls, dupreqs), `mount | grep nfs` for the real options.
`soft` mounts return errors instead of hanging (usually what you want for
non-critical paths); `hard,intr` — `intr` is obsolete and ignored on modern Linux, so
do not rely on it; `timeo`/`retrans`/`vers=4.2`/`proto=tcp`/`nconnect=` (parallel
TCP sockets) are the practical levers; `noresvport` for failover to a clustered
server; `sync` vs default async changes commit semantics and latency massively;
`_netdev` and `x-systemd.automount` in fstab stop boot hangs after a server outage.
Stale file handle = the inode vanished server-side (or a filesystem was re-exported):
clients must unmount/remount; a process holding it stays `D` until it releases.
Root-squash makes root writes fail in a way that reads "permission denied" while SELinux
is the usual *other* suspect — check both, then `exportfs -v` for the real mask.
`idmap`/NFSv4 domain mismatches show as `nobody` ownership.
FUSE (`s3fs`, `sshfs`, `fuse-overlayfs`): a crashed daemon leaves every reader in `D`
until the mount is killed (`fusermount -uz`); FUSE latency is user-space round-trip, so
`ls -R`/stat-heavy apps are pathological. Treat FUSE mounts as untrusted for
locking-heavy software (databases on FUSE = corruption).
