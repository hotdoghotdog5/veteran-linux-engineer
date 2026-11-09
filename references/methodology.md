# Methodology: how a veteran actually works

Contents
- [1. The debugging loop, expanded](#1-the-debugging-loop-expanded)
- [2. First moves on an unfamiliar or broken box](#2-first-moves-on-an-unfamiliar-or-broken-box)
- [3. Layer model: where the fault lives](#3-layer-model-where-the-fault-lives)
- [4. "What changed?" — the highest-yield question](#4-what-changed--the-highest-yield-question)
- [5. USE method for resources](#5-use-method-for-resources)
- [6. Hypothesis discipline and bisecting](#6-hypothesis-discipline-and-bisecting)
- [7. Latency accounting: where did the time go](#7-latency-accounting-where-did-the-time-go)
- [8. Baselines: nothing is slow in the abstract](#8-baselines-nothing-is-slow-in-the-abstract)
- [9. Red herrings and self-inflicted outages](#9-red-herrings-and-self-inflicted-outages)
- [10. Root cause analysis and postmortem](#10-root-cause-analysis-and-postmortem)
- [11. Working under pressure: incident command for one](#11-working-under-pressure-incident-command-for-one)
- [12. Learning, teaching, and escalation](#12-learning-teaching-and-escalation)
- [Sources](#sources)

## 1. The debugging loop, expanded

Formal debugging frameworks converge on the same shape: observe, explain, predict,
control. The Google SRE book's framing is scientific method applied to systems —
gather data, form a hypothesis, make a *prediction* the hypothesis implies, run an
experiment that can falsify it, and change exactly one variable at a time. The
prediction step is the one everyone skips and the one that separates debugging from
thrashing: if your hypothesis does not imply something you have not yet checked, it is
a feeling, not a hypothesis.

Concrete pass through the loop:

0. **Classify.** Outage (users hurting now) or investigation (nothing on fire)?
   Outage → mitigation track: roll back, fail over, scale, restart the narrow thing.
   Investigation → diagnosis track: preserve evidence before you change anything.
   Never run both tracks in the same hand. Write down which one you are in.
1. **Observe.** Reproduce the failure and capture the baseline bundle (§2). Get the
   exact error text, exact timestamp, exact host. "Sometimes" is a different problem
   than "always" — quantify the rate before you start.
2. **Orient.** Which layer (§3)? What changed (§4)? Is this a resource limit, a
   correctness bug, a configuration drift, or a dependency failing?
3. **Hypothesize.** Write 2–4 causes ranked by (probability × cheapness-to-test).
   Each must explain *all* symptoms, including the ones that seem unrelated. A
   hypothesis that only explains the headline symptom is usually a symptom of a
   hypothesis.
4. **Test.** Choose the check with the highest information per unit risk. Prefer
   read-only. Predict the reading if the hypothesis is true *and* if it is false; a
   test that cannot distinguish them is theatre.
5. **Act.** Smallest reversible change that removes the user-visible problem.
6. **Verify.** Same metric as step 1, same window, plus the error counter you watched.
   Keep watching for longer than the change took.
7. **Record.** Timeline, mechanism, contributing factors, prevention. If you cannot
   state the mechanism, you mitigated, you did not fix — say that in the note.

Anti-patterns to refuse: fixing the last thing you read about; applying "tuning" knobs
before locating the bottleneck; debugging a non-reproducible problem by adding a
workaround to production; running the same failing command four times; treating
"no errors in the log" as "the log is clean" (wrong log, wrong boot, filtered unit,
rate-limited).

## 2. First moves on an unfamiliar or broken box

Read-only triage bundle — safe, fast, and 80% of the context you need. Adapt names to
what is installed; check for absence rather than assuming.

```sh
uname -a; cat /etc/os-release; uptime; date -u            # what/where/how long/clock
systemctl --failed --no-legend                            # what systemd already blames
journalctl -p err -b --no-pager | tail -50                # this boot, errors and worse
journalctl -k -b --no-pager | tail -50                    # kernel: OOM, IO errors, drops
dmesg -T --level=err,warn | tail -50                       # pre-journald / raw ring
df -h; df -i; findmnt                                     # space, inodes, mount reality
free -h; cat /proc/pressure/*                             # memory + PSI all three
ps aux --sort=-%cpu | head; ps aux --sort=-%mem | head    # who is eating what
ps -eo pid,stat,wchan:28,cmd | awk '$2 ~ /D/'             # uninterruptible = blocked
ss -ltnp; ss -s                                           # listeners, socket census
ip -br a; ip route get 1.1.1.1; resolvectl status 2>/dev/null || cat /etc/resolv.conf
systemd-analyze blame | head                              # slow boot history
last -n 10; who; systemctl list-timers --no-legend | head # who/what ran recently
```

Then look at the *specific* thing asked about — the unit, the mount, the interface, the
file. Do not generalize from a machine-wide scan to a service-level conclusion.

`uptime`/load discipline: a load number is meaningless without core count and without
the split between runnable and blocked. Read `vmstat 1 5` (`r` and `b` columns) or
`cat /proc/loadavg` alongside `nproc`, then `ps` for `D`-state processes. High load with
idle CPUs means blocked work — storage, NFS, a kernel lock, not "CPU".

## 3. Layer model: where the fault lives

Order of distrust, cheapest first. A fault is at exactly one layer even when it
manifests at another.

1. **Physical / provider.** Cable, SFP, switch port, power, disk health, BMC SEL,
   cloud provider status, an egress outage, an expired card, a maintenance event,
   a hypervisor migration. Check before blaming software.
2. **Firmware/BIOS/BMC.** Microcode, buggy BIOS power management, iDRAC/iLO sensor
   floods, Secure Boot rejecting a module, NIC firmware.
3. **Kernel & drivers.** Version and taint (`uname -r`, `lsmod`, `dmesg | grep -i taint`),
   module mismatch after an upgrade, known regression for this kernel (search the
   distro bug tracker before your own).
4. **Resources.** CPU, memory, storage, network capacity, file descriptors, pids,
   conntrack entries, inodes, threads, ports. Limits bind before capacity does.
5. **Init/system & services.** Unit ordering, dependencies, sockets, timers,
   cgroup limits, SELinux/AppArmor, PAM, dropped privileges.
6. **Middleware/runtime.** DNS resolution, TLS certs and SNI, proxies, load balancers,
   database pools, JVM/Node heap-vs-cgroup awareness, GC.
7. **Application.** Logic, concurrency, retries and timeouts amplifying a small fault.
8. **Client/observer.** The reporter's laptop, VPN, cache, a stale monitoring probe,
   or a test that measures the wrong thing. Rule out the thermometer before the fever.

Technique: for each layer, find the *boundary counter* — the place where you can prove
data arrived and did not leave. NIC counters prove the wire; `ss`/`nstat` prove the
kernel TCP stack; access logs prove the app accepted; the client proves it sent. When
the counters disagree, the fault is between them.

## 4. "What changed?" — the highest-yield question

Most outages follow a change that someone believed was safe. Enumerate mechanically:

```sh
# Package/kernel changes
rpm -qa --last | head -25                # RHEL/Fedora/SUSE
dpkg -l | sort -k6 | tail -25            # Debian/Ubuntu (install/upgrade times)
grep -H . /var/log/dnf.rpm.log 2>/dev/null | tail -20
grep -HE 'Upgrade:|Install:' /var/log/dpkg.log* 2>/dev/null | tail -20
uname -r; ls -la /boot                   # running kernel vs newest installed
# Config drift: files modified in the last day
find /etc -type f -newermt '-1 day' -printf '%TY-%Tm-%Td %TH:%TM %p\n' 2>/dev/null | sort
# Who did what
last -n 25; grep -H sudo /var/log/auth.log* 2>/dev/null | tail -20   # or journalctl -t sudo
journalctl _COMM=sudo --since '-3 days' --no-pager | tail -30
# Service state and recent failures
systemctl list-units --state=failed; systemctl list-timers --all | head
# Firewall and network edits
nft list ruleset | head -40; ss -ltn | wc -l
# Cloud/control-plane driven: asg/template/IaC apply, autoscaler, k8s rollout, mgmt agent
```

Also "what changed" in ways nobody edits: certificates expiring (check
`openssl x509 -enddate -noout -in <crt>`), disk wear (`nvme smart-log`), a peer
deploying, DNS TTL expiry, a cron at month end, a log volume spike, seasonal load,
temperature, and time sync drift.

Deployed config management? Diff the rendered file against reality before editing by
hand — and know that the next `agent run` will overwrite your hot fix. Say so out loud.

## 5. USE method for resources

Brendan Gregg's USE method: **for every resource, check Utilization, Saturation,
Errors.** It is a checklist generator, not a metric to eyeball backwards from.
Utilization = fraction of time the resource is busy (or fraction of capacity used);
Saturation = the queue or wait behind it (run-queue length, disk queue, swap,
`nr_throttled`); Errors = error counters. Check errors first — they are usually
cheaper and less ambiguous.

Enumerate resources before metrics: every CPU (and core), every memory tier (RAM,
swap/zram), every storage device *and* the controller, interconnect (network interface,
bus, PCIe), kernel structures (inodes, dentries, conntrack, file tables, sockets,
thread/pid limits), and software pools (DB connections, app worker pools, JVM heap).
Software resources saturate exactly like hardware and are usually missed.

Per-resource queue metrics matter more than percentages. A disk at 100% `%util` with
`aqu-sz` 0.1 is not a bottleneck; four threads on a 128-core box reading "load 4" is
not a CPU problem. See `references/toolbox.md` for the reading rules per tool.

Related framing worth stating explicitly when you present findings: **the bottleneck is
where the queue is.** Find the longest queue, then explain why it is long. Reducing
pressure upstream of a queue beats adding capacity to it if the queue exists because of
a latency or correctness defect (e.g. a synchronous stat call, a lock convoy, a retry
storm).

## 6. Hypothesis discipline and bisecting

- **Reproduce first.** A deterministic local reproduction is worth more than an hour of
  speculation about production. Reduce it to the smallest case that still fails — that
  minimal case is what you will test hypotheses against and what you will attach to an
  upstream bug report.
- **Bisect anything with an ordering.** Versions (`git bisect` on the repo, manual
  kernel/boot bisect against distro builds), config files (comment out half), datasets
  (halve the input), time (when did the metric first break — bisect the window), and
  change sets (binary-search deploys). Bisection turns O(n) guessing into O(log n).
- **Differential diagnosis.** "Works here, fails there" is the strongest signal in the
  trade. Diff everything: kernel, glibc, config, environment, cgroup, mount options,
  DNS, clock, locale, timezone. `systemd-analyze dump` and `rpm -qa | sort > before`
  style snapshots make this mechanical.
- **Vary one thing.** If you change two and it passes, you have a working box and no
  knowledge — and an un-revertible state.
- **Cheapest discriminating test first.** Prefer the test that can *kill* a hypothesis.
- **Negative evidence is evidence.** Record what you ruled out and how. It stops the
  next person (or you, in six months) from re-walking the dead ends.
- **When the data contradicts the model, the model is wrong.** Do not add a knob to
  make the symptom agree with your theory.
- **Instrument rather than infer.** `strace -f -tt -T -p <pid>`, `ss -ti`,
  `bpftrace` one-liners, or an added log line give you the mechanism directly. A
  veteran's reflex is "how would I *see* this happen", not "what would explain this".

## 7. Latency accounting: where did the time go

For "it is slow", decompose the latency budget instead of arguing about load.

1. Quantify: p50/p95/p99 for the operation, not the average. Averages hide the tail
   that generates tickets. Use `perf latency`, `bpftrace` histogram probes (`hist()`),
   `nstat -s 1` style sampling deltas, or the app's own timing logs.
2. Split the request: client → network RTT → accept queue → app queue → dependency
   (DNS, DB, cache, disk) → CPU compute → return. Measure at each boundary; the big
   jump localizes the fault.
3. Ask on-CPU or off-CPU? If the thread is running, profile it (`perf record`,
   `profile-bpfcc`, flame graphs). If it is waiting, account the wait (`offcputime`,
   `wchan`, `schedstat`, PSI). Most production slowness is off-CPU and gets missed
   because `top` looks idle.
4. Apply Little's law to sanity-check: concurrency ≈ throughput × latency. If observed
   queue depth and latency do not multiply out, one of your measurements is wrong or
   you have a hidden serialization.
5. Then and only then: is this a capacity problem, a concurrency/lock problem, or a
   per-operation latency problem? Each has a different fix and adding CPU only helps
   the first.

## 8. Baselines: nothing is slow in the abstract

You cannot diagnose a deviation you never measured. Before the incident, or as the first
step of it, capture what normal looks like:

- Kernel and distro level: `uname -a`, `cat /etc/os-release`, `rpm -qa`/`dpkg -l`
  snapshots, `sysctl -a` dump, `lscpu`, `lsblk -f`, `ip a`, `nft list ruleset`.
- Per-service steady-state: request rate, p99 latency, error rate, CPU/mem/disk per
  unit (`systemctl status` shows cgroup consumption), open FDs, thread count, conntrack
  entries, load distribution across cores.
- Device norms for the hardware you actually have — read them once from a healthy box
  and write them down, so you are comparing to *your* fleet, not to a blog.
- Capture the same window before and after a change; identical window length, identical
  sampling command. Otherwise you are comparing noise to noise.

Persist the baseline somewhere the box dying does not take it with you. On disk
saturation analysis, memory pressure analysis, and any "the whole rack is slow" ticket,
the baseline is the difference between engineering and guessing.

## 9. Red herrings and self-inflicted outages

Veteran reflex order when the story does not add up:

1. Wrong target — wrong host, wrong environment, wrong container vs host, stale
   terminal, SSH session to a jump box that already moved, edited the file the package
   manager does not read (`/lib` vs `/etc`, drop-in shadowing, `conf.d` last-wins),
   running as a different user, `sudo -E` env differences.
2. Stale observation — cached page, browser/CDN cache, DNS cache (client, resolver,
   JVM `networkaddress.cache.ttl`), monitoring lag, a dashboard with a 5-minute window,
   a log you are tailing that journald rate-limited.
3. Clock/timezone — skew breaking TLS/Kerberos/consensus, a machine in the wrong year,
   cron firing at an unexpected wall time, DST, a clock that jumped after suspend.
4. The obvious resource — disk full (blocks *and* inodes *and* reserved blocks *and*
   deleted-but-open files), FD limit, pid limit, conntrack full, ephemeral port
   exhaustion, `nofile` in the unit vs the shell.
5. Half-applied change — service not restarted after config edit, `daemon-reload`
   skipped, `systemctl restart` vs `try-restart`, a new kernel installed but not
   booted, a package held, a stale module in initramfs, a change not propagated by
   the CM agent, a firewall rule saved but not applied (or applied but not saved).
6. The dependency two floors down — the database, the identity provider, the metadata
   service, NTP, DNS, the storage array's peer, the vendor's API.
7. Your own debugging — tracing a high-rate syscall path, `strace` on a hot service,
   `perf record` at high frequency in production, `tcpdump` on a saturated 100 Gb link,
   `journalctl -f` over a laggy SSH session, an `strace -p` you forgot to detach.
   Measure with cheap counters first, expensive probes for seconds not hours.
8. "It worked before" is not "it should work" — verify whether the previous success was
   on this code path at all.

And the meta-rule: when two independent systems disagree, both are giving you correct
information about different things. Find the discrepancy boundary; that is where the bug is.

## 10. Root cause analysis and postmortem

Mitigation closes the ticket; RCA prevents the recurrence. Separate them in writing.

- Build a **timeline** with timestamps from machine sources (journal, `sshd` auth log,
  package logs, monitoring alerts) rather than memory. Anchor the first
  abnormal observation.
- Distinguish **root cause** (the defect that allowed it), **trigger** (what set it
  off), **contributing factors** (why detection was slow, why the blast radius was
  large, why the rollback was hard), and **symptoms**.
- Ask "why" until you reach something *changeable* — usually a missing guardrail,
  a silent failure mode, or a design assumption. Stop when the next why is "because
  humans". Five whys is a starting heuristic, not an algorithm; single-root-cause
  thinking is the failure mode to avoid in complex systems, where incidents are
  normally emergent from several jointly-sufficient conditions.
- **Blameless by construction.** Critique the design and the guardrails, never the
  person. The engineer who broke prod at 03:00 and is scared to tell you is the most
  expensive outcome available; information hiding is what turns one outage into the
  next one. People who work around a broken process are telling you the process is
  broken.
- Make **action items** owned, dated, and verifiable ("add alert on `ce_count`
  delta"), not aspirational ("be careful with LVM"). Verify one next month.
- Write it so a stranger can re-derive your reasoning in six months — including the
  dead ends. Practitioners' repeated advice on the record: document not for the
  successor but because future-you will not remember ("I document everything because in
  6 months I'll come back to it and be like, 'How the hell did I do this?'"), and
  "if it isn't in writing, it didn't happen".

Template in `references/safety.md` §6.

## 11. Working under pressure: incident command for one

- Declare the incident early and widen the circle early. Two people reviewing a
  command beats one guessing alone; a scribe frees the driver to think.
- **Mitigate before you diagnose.** Restore service by the least destructive means
  (rollback > failover > scale > restart), keep the evidence needed for diagnosis
  (dump the journal, snapshot, save `/proc`, keep the core file), and let the
  investigation continue after users are back. Sacrificing a dead box for forensics is
  correct; sacrificing live service for a cleaner root cause is not.
- Timebox. If two hypotheses fail, step back and re-observe — you are probably in the
  wrong layer. Set a hard clock for "if not mitigated by T, we do X (rollback/escalate)".
- Escalation is a skill, not a failure. Escalate when: blast radius grows, you cannot
  name the failing layer, the fix requires a Class C action on data you cannot back up,
  you have been at it past the timebox, or the change is outside your authority.
  Escalate with the bundle: what is broken, since when, what is impacted, what you
  ruled out, what you tried, what you need.
- Announce before mutating prod and after it landed. Silence during an outage creates
  a second incident (panic, uncoordinated fixes) on top of the first.
- Never fix production to avoid admitting a mistake. Revert, tell, fix deliberately.
  Own it, show the mechanism, show the prevention — the record of a well-handled
  outage builds more trust than an unbroken one.
- The psychological anchor from decades of practice: a broken server is a
  solvable engineering problem; your judgement, health, and relationships are not
  recoverable by a rollback. Nothing about a machine justifies shortcutting the safety
  rules in `references/safety.md`.

## 12. Learning, teaching, and escalation

- Read upstream sources when it matters: the distro's own docs beat a blog post; the
  `Documentation/` tree at docs.kernel.org and the `man-pages` info pages
  (`man 7 <topic>`, e.g. `man 7 cgroups`, `man 7 proc`, `man 7 ip`) beat both.
  When explaining a fix, name the source so the next person can check you.
- Reproduce unfamiliar behaviour in a throwaway VM instead of on the box you are
  asked to fix — and read what the kernel prints when you break it deliberately.
  That is how the model gets built.
- Teach on the way out: after the fix, one or two sentences on mechanism, plus what
  would have caught it earlier. Documentation and runbooks written to be executed at
  03:00 by someone who has never seen the system are worth more than any clever fix.
- Recurring incident in the same subsystem is a project, not a ticket: after the third
  time it is a pattern, and patterns get design work, tests, alerts, or automation.

## Sources

- Google SRE Book — *The Art of Debugging* (scientific method / hypothesis–prediction–
  experiment, one variable at a time), *Incident Response*, *Postmortem Culture*:
  https://sre.google/sre-book/table-of-contents/
- Google SRE Workbook — alerting on SLOs, practical alert design, managing temporary
  problems: https://sre.google/workbook/table-of-contents/
- Brendan Gregg, *The USE Method* (errors-before-utilization note; saturation as queue
  length; disk non-preemptibility and queueing above ~70% busy):
  https://www.brendangregg.com/usemethod.html
- Brendan Gregg, *Linux Performance* (tool catalogue and methodology index):
  https://www.brendangregg.com/linuxperf.html
- Gregg, *Systems Performance* 2nd ed. (offline analysis, 60-second breakdown)
- Limoncelli, Chalup, Kaczmarek, *The Practice of System and Network Administration*
  (golden rules, documentation, standards, disaster recovery, "never be a hero")
- John Allspaw / David Marx on blameless postmortems, just culture, and why
  single-cause narratives fail in complex systems
- Rinaldi, "How I debug" style practitioner writing; Julia Evans' zines and
  https://jvns.ca/ for syscall/strace/perf mechanics
- LLM-driven RCA literature (for calibrating how much to trust agent diagnosis):
  [Automated Root Causing of Cloud Incidents using In-Context Learning with GPT-4](https://consensus.app/papers/details/49c988b5c577570fa55f9461cebc308e/)
  (Zhang et al., FSE 2024); [Empowering Practical Root Cause Analysis by LLMs for Cloud
  Incidents](https://consensus.app/papers/details/4094fc5d27a850d492f3c8187ff28011/)
  (Chen et al., 2023); [Root Cause Analysis for Cloud-Native
  Applications](https://consensus.app/papers/details/e0885d78050b506eb3b9f3494f05335c/)
  (Żurkowski & Zieliński, IEEE TCC 2024)
- Practitioner habits: r/sysadmin [Once a young sysadmin and now an old
  unicorn](https://reddit.com/r/sysadmin/comments/dzm3xs/once_a_young_sysadmin_and_now_an_old_unicorn_how/)
