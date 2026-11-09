# Subsystems field guide: networking

Reachability and throughput, TCP deep dive and packet loss, DNS and name resolution.

Contents
- [7. Networking: reachability and throughput](#7-networking-reachability-and-throughput)
- [8. TCP deep dive and packet loss](#8-tcp-deep-dive-and-packet-loss)
- [9. DNS and name resolution](#9-dns-and-name-resolution)

## 7. Networking: reachability and throughput

Work the stack by boundary, using the tool that owns each boundary:

```sh
ip -br a; ip route; ip route get <dst>; ip rule show; ip neigh show
ss -ltnp; ss -tan state established | wc -l; ss -s
ip -s -s link show dev eth0        # rx/tx errors, dropped, fifo, compressed
ethtool -S eth0 | egrep -i 'drop|err|miss|no_buffer|pause|disc'   # NIC/driver truth
ethtool -i eth0; ethtool -k eth0 | grep -i offload; ethtool -c eth0
nstat; nstat -s 1                  # sampled kernel counter deltas
cat /proc/sys/net/netfilter/nf_conntrack_count /proc/sys/net/netfilter/nf_conntrack_max
dmesg -T | egrep -i 'link (down|up)|nf_conntrack: table full|tcp: out of memory|ARP'
nft list ruleset ; iptables-save 2>/dev/null | head    # which backend is live
tc -s qdisc show ; cat /sys/class/net/eth0/queues/rx-*/napi_id   # offloads/ring
lspci -vv -s <nic> | egrep 'LnkSta|Kernel driver'       # link width/speed surprises
```

**Reachability decision tree.** `ping` (if ICMP is not filtered) → `ip route get` →
`ip neigh` (ARP/NDP → L2) → `ss -ltnp` on the server (is anything bound, and on which
address: `0.0.0.0` vs `127.0.0.1` vs a specific IP) → `syn` reaches or not
(`tcpdump -ni any host <peer> and port <p> -c 50`) → local firewall (`nft list
ruleset`, plus cloud security group / provider ACL) → listener accept queue → app.
Connection **refused** = nothing listening or a firewall REJECT/ICMP-port-unreach.
Timeout with no reply = dropped somewhere (filter, route asymmetry, MTU blackhole,
conntrack full, dead peer). Immediate RST from peer = peer's app or a middlebox.

**MTU/PMTU blackholes.** Handshake fine, big transfers stall → classic PMTUD blackhole
from ICMP-frag-needed being blocked. Verify `ip link` MTU on every hop incl. VLAN/bond/
tunnel/VXLAN overlays (tunnel overhead eats 50–100 bytes), test with
`ping -M do -s 1472 <dst>`, and check `tcp_mtu_probing` and `ip forward_pmtu_disc`.
Container/Pod MTU mismatch with the underlay is the most common "sometimes slow" bug on
overlay networks.

**Softirq/queues.** Drops in `netdev:` backlog (`softnet_stat`, second column = drops)
mean the CPU processing the NIC interrupt can't keep up: check RSS/RX queue count vs
cores, `irqbalance` or pinned IRQs, `rx/tx` ring sizes (`ethtool -g`), GRO/GSO/TSO
offload, and `tc`/`nft` CPU cost; consider XDP for drops at the earliest point.

## 8. TCP deep dive and packet loss

**Retransmits are a symptom, not a cause** — at least four distinct mechanisms produce
them. Identify the mechanism from counters before touching any `net.ipv4.tcp_*` knob.

```sh
nstat -az TcpRetransSegs TcpExtTCPLostRetransmit TcpExtTCPFastRetrans \
           TcpExtTCPSlowStartRetrans TcpExtTCPSynRetrans TcpExtTCPTimeouts
nstat -s 1                      # deltas over a window: the operationally useful number
nstat -az | egrep 'Listen|TCPReqQ|TCPSynRetrans|OutDiscards|OutNoRoutes|InCsumErrors'
ss -tin state established       # per-socket: retrans, rto, irtt, cwnd, pacing_rate, rcv_space
ss -ltn                         # Send-Q on a listener = backlog limit, Recv-Q = current accept queue
cat /proc/sys/net/ipv4/tcp_keepalive_time ; cat /proc/sys/net/ipv4/ip_local_port_range
dmesg -T | grep -i 'nf_conntrack.*table full'
dropwatch -l kas                # where the kernel freed skbs it never delivered
tcpdump -ni eth0 'host <peer> and port <p>' -s0 -w /tmp/x.pcap
```

Counter → meaning (short form): `TCPSynRetrans` = SYN or SYN-ACK unanswered → path,
ACL/NAT, listener backlog, or conntrack, not congestion. `ListenDrops`/
`ListenOverflows` = application is not calling `accept()` fast enough (or `backlog` too
small) → fix the app/pool, not the kernel. `TCPReqQFullDoCookies`/`Drop` = SYN-flood
defense engaging. `TcpRetransSegs` on established flows = real loss or an RTT/RTO
problem; check both directions because a lost ACK causes retransmits of data that
arrived. `InCsumErrors` = bad NIC offload/cabling. `OutDiscards`/`OutErrors` +
`tx_dropped` = TX queue full/scheduler. `rx_missed_errors`/`rx_no_buffer_count` = NIC
ring overrun → ring size, RSS, or CPU.

**Latency vs loss.** Distinguish bufferbloat (RTT inflates under load, loss is low)
from genuine loss (RTT stable, loss bursty) from path asymmetry from a throttled cloud
volume. Measure: `ss -ti` `rtt`, `ping -c 100` stats, `mtr -zw 50` (per-hop loss is
usually ICMP policy, only end-to-end loss counts), and `bpftcp`/`tcplife`/`tcpconnect`
from bcc for connection-level census.

**Congestion control.** `sysctl net.ipv4.tcp_congestion_control` (per-socket via
`ss -ti`); `cubic` default, `bbr` for long-fat/wan links — but BBR needs
fq qdisc (`tc qdisc replace dev eth0 root fq`) to behave, and applying it globally
without measurement is how you make one tenant's problem everyone's. `tcp_rmem`/
`tcp_wmem`/`tcp_moderate_rcvbuf` and window scaling (`ethtool -k | grep scaling`)
before blaming the app for slow bulk transfers. `TIME_WAIT` accumulation is usually
healthy short-connection behaviour; only hits `ip_local_port_range` limits — check
`tw_reuse`/`tcp_tw_reuse` (outbound only, safe with timestamps) before inventing
`tcp_max_tw_buckets` hacks. `tcp_fin_timeout` shortening is close to useless and can
break conformance.

**Keepalive & idle disconnects.** Silent idle connections dying at a round number
(60s/300s/3600s) = an NAT/conntrack/LB idle timeout. Confirm with conntrack
`nf_conntrack_tcp_timeout_established` and the middlebox; fix with application-level
heartbeats or `tcp_keepalive_*` shorter than the idle timer.

## 9. DNS and name resolution

**Test the path your program uses, not `dig`.** `dig` asks a chosen server a chosen
record and bypasses NSS, the stub resolver, search lists, and caching — so it proves
upstream, not your host. Compare:

```sh
getent hosts <name>              # full glibc/NSS path (what your app does)
resolvectl query <name>          # what systemd-resolved answers
resolvectl status                # per-link DNS servers, protocols, DNSSEC/DNS-over-TLS
cat /etc/nsswitch.conf | grep ^hosts
ls -l /etc/resolv.conf; cat /etc/resolv.conf
dig +short <name>@<upstream> ; dig <name> NXDOMAIN-test.invalid   # timeout vs NXDOMAIN
```
`dig` works but `getent` fails → NSS/search/hosts/stub problem, not DNS.
A lookup of `*.invalid` that *resolves* means something local is answering (wildcard
upstream, captive portal, a local resolver synthesizing); a *timeout* is transport, an
*NXDOMAIN* is an answer.

Resolution order: `files` (`/etc/hosts`) → `dns` (glibc reading `/etc/resolv.conf`) or
`resolve`/`resolved` (via `libnss-resolve` to `systemd-resolved`) → `myhostname`,
`mdns4_minimal`. If neither `dns` nor `resolve` appears in `nsswitch.conf` `hosts:`,
glibc may never query DNS at all. `/etc/resolv.conf` being a symlink to
`/run/systemd/resolve/stub-resolv.conf` (nameserver `127.0.0.53`) means resolved owns
the upstreams; a real file there means something else writes it (NetworkManager,
dhclient, a container image, or a hand edit that will be reverted).

**Latency and timeouts.** glibc defaults: `timeout:5`, `attempts:2` per server, all
`nameserver`s in order (no parallel racing by default → a single dead server costs
10 s per lookup). `options timeout:1 attempts:1 rotate single-request-reopen` is the
usual band-aid; the real fixes are a reachable local resolver or a health-checked pair.
`search` + `ndots:5` (Kubernetes default) makes every single-label name try every
search domain first: five queries before the real one, which is why "DNS is slow" inside
clusters and why FQDNs ending in `.` fix it. Check `resolv.conf` `edns0`, IPv6
`AF_INET6` attempts (`options single-request`), and conntrack UDP timeout for
high-query-rate resolvers.

**Caches that lie.** systemd-resolved (`resolvectl flush-caches`), `nscd`/`sssd`
(if installed, `nscd -i hosts`), JVM negative/positive caching
(`networkaddress.cache.ttl`), glibc `LD_PRELOAD` hacks, container `--dns`, browser/OS
resolver caches, and cloud provider resolvers (`.169`/`.172`-style anycast endpoints
with their own behaviour).
