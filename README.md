# ansible-dfkv

Ansible automation for [DingoCache](https://github.com/dingodb/DingoCache)
(`dfkv`): etcd, `dfkv_mds` and `dfkv_server` on Linux.

This repo holds code — playbooks, roles and templates. Cluster configuration
lives in a separate, private inventory repository, one directory per datacenter.
See [Driving this from a region inventory](#driving-this-from-a-region-inventory).

## Prerequisites

- A control node that can reach every target over SSH, with `kubectl` if the
  region's cache nodes are discovered from a Kubernetes cluster.
- Ansible core 2.13 or newer, plus the collections in `requirements.yml`:

  ```bash
  ansible-galaxy collection install -r requirements.yml
  ```

- `root` SSH access to the targets. dfkv creates no service account: binaries,
  data directories and systemd units are all root-owned.
- For cache nodes, an RDMA-capable node with the userspace providers installed.
  The prepare role installs them, but a node with no HCA cannot serve.

## Repository Structure

```
ansible-dfkv/
├── ansible.cfg
├── requirements.yml
├── inventory/
│   ├── hosts.yml                  sample inventory, six groups
│   └── group_vars/all.yml         defaults; a region copies this and overrides
├── playbooks/
│   ├── 00_check_config.yml        preflight: the region's group_vars is complete
│   ├── 01_prepare.yml             packages, directories, RDMA check
│   ├── 02_release.yml             fetch and stage a release (no restart)
│   ├── 03_etcd.yml                bootstrap the etcd quorum (greenfield)
│   ├── 04_mds.yml                 deploy dfkv_mds
│   ├── 05_server.yml              deploy dfkv_server
│   ├── 06_verify.yml              assert against the ring
│   ├── 07_observability.yml       per-region telemetry stack
│   ├── 08_client.yml              publish the client tree to shared storage
│   ├── 90_upgrade.yml             rolling upgrade / rollback
│   ├── 91_uninstall.yml           remove dfkv (destructive; two gates)
│   ├── 99_status.yml              read-only status report
│   ├── dfkv_site.yml              full bring-up: control plane + cache ring
│   └── dfkv_gpu_site.yml          bring up a batch of cache (GPU) nodes
└── roles/
    ├── dfkv_prepare/
    ├── dfkv_release/              stage + activate; owns the launchers
    ├── dfkv_etcd/
    ├── dfkv_mds/
    ├── dfkv_server/
    ├── dfkv_observability/
    ├── dfkv_client/
    └── dfkv_verify/
```

## Inventory and groups

Roles are selected by **group**, never by a node-name pattern. The tooling this
replaces inferred "is this an MDS?" from `*-cpu-*` in the hostname, which was
wrong in bj11 — its MDS nodes are named `bj11-dingofs-00NN` — so an unfiltered
upgrade restarted `dfkv-server` on them.

| Group | Holds | Notes |
|---|---|---|
| `etcd_servers` | the etcd quorum | **not** in Kubernetes. 1 node for dev, 3 for production. |
| `mds_servers` | `dfkv_mds` replicas | stateless; usually the same hosts as `etcd_servers` |
| `cache_servers` | `dfkv_server` cache nodes | the GPU nodes; in Kubernetes in production |
| `observability_servers` | the telemetry stack | normally one of the MDS nodes |
| `client_stage` | publishes the client tree | any host that can see the shared mount |
| `admin` | control-plane bookkeeping | nothing is deployed here |

`etcd_servers` and `mds_servers` are separate groups rather than one because the
two roots may differ: bj09 runs MDS from `/root/dfkv` while its servers use
`/root/dfkv2`. A node's root is derived from its group membership and never from
its name.

### Per-node values

Everything that used to be a region-wide, string-keyed map is an ordinary host
variable on the node it applies to:

```yaml
cache_servers:
  hosts:
    bj11-gpu-300b-0001:
      ansible_host: 11.11.3.1
      dfkv_weight: 1
      dfkv_advertise_iface: roce2003
      dfkv_rdma_dev: ib8s800p0
      dfkv_ram_tier: true
      dfkv_ram_tier_bytes: 137438953472  # 128 GiB
```

Capacity is deliberately **not** a per-node variable. It is derived from the
disks the node actually has — see [Capacity and disk selection](#capacity-and-disk-selection).

The previous design kept these as `SERVER_CAP_MAP="n1:1;n2:2"` strings matched
against `$(hostname)` inside the launcher. That worked, but it meant the map key
had to be the OS hostname while every other map keyed on the inventory name —
and hd04's cap map was written with Kubernetes names, so it silently did
nothing. With host variables there is nothing to mismatch.

## Capacity and disk selection

`dfkv_server` sizes itself as **a fraction of each disk it finds**, not from a
number written into region config:

```
1. discover every /mnt/disk*
2. drop anything below dfkv_min_disk_gb
3. keep only the largest same-size group (within 1%)
4. per-disk share = smallest disk in that group x dfkv_disk_usage_ratio,
   rounded DOWN to a whole 1 GiB extent
5. --cap = per-disk share x number of disks in the group
```

This is ported from `roles/dingo_cache` in ansible-dingofs on purpose: cache
nodes run both systems over the same NVMes, so both select disks the same way.

**Step 3 is doing more work than it looks like.** dfkv splits `--cap` evenly
across its directories (`base_capacity = cap / n`) and applies **one**
`--disk-hash-weight` to **every** disk — its CLI has no per-disk form for either.
Both are only correct when the disks are the same size. By handing dfkv a
same-size group, homogeneity is established before dfkv sees the disks, so its
uniform weight is capacity-proportional by construction. Nothing has to change
in dfkv itself.

Without step 3 a mixed node would be **actively broken**, not merely suboptimal:
the small disk receives the same `cap/n` budget as the large ones and fails when
slab tries to lay down extents it cannot fit.

Rounding down in step 4 is what satisfies dfkv's extent rule: the total is then
`count x per_disk`, a whole multiple of `count x 1 GiB` by construction. (This is
the constraint that re-cut bj09: 10 TiB across 6 disks is 1706.67 GiB each and
the server refused to start.)

### Sharing the disks with dingo-cache

Both systems are configured as a fraction of the same disks. Measured
2026-09-22, dingo-cache runs at `0.80`; dfkv at `0.50` adds up to 1.30 of the
disk. That is fine, and deliberately so: dingo-cache grows on demand and evicts,
so it settles below its own ceiling rather than failing. What it cannot do is
grow into space dfkv has already taken — **dfkv preallocates its share as extent
files on first start and never gives it back**, so dfkv's ratio is the number
that actually has to be right.

A per-disk budget that adds up to more than 1.0 is therefore not an error here,
but it does mean dingo-cache's configured `cache_size_mb` is a ceiling it will
never reach. Size the cluster against what it can actually get, not against what
it is configured with.

### Changing capacity on a running node

`dfkv_server_wipe_on_capacity_change` is off by default. A node whose derived
capacity no longer matches what it is running needs an explicit
`-e dfkv_server_wipe_on_capacity_change=true`, because slab will not reopen a
directory laid out for a different capacity — it fails with "existing slab
layout differs from requested geometry" and the service restart-loops
(measured, bj09-gpu-200b-0022, 2026-09-22). The flag stops the service, removes
the data directories and lets dfkv recreate them at the new capacity, so the
node serves misses until it refills. Run it in a window, and one node at a time:
`-e dfkv_server_serial=1`.

## Deployment phases

Playbooks are numbered for the order they run in, so `ls playbooks/` reads as the
deploy sequence: **00-08** are the bring-up chain, **90-98** are lifecycle actions
(upgrade, uninstall), **99** is read-only.

| Step | Playbook | Target | What it does |
|---|---|---|---|
| — | `00_check_config.yml` | all | preflight: the region's group_vars is complete |
| 01 | `01_prepare.yml` | all | packages, directories, RDMA device check |
| 02 | `02_release.yml` | MDS + cache | fetch once, push, stage |
| 03 | `03_etcd.yml` | `etcd_servers` | bootstrap the quorum |
| 04 | `04_mds.yml` | `mds_servers` | env, unit, start, wait for ready |
| 05 | `05_server.yml` | `cache_servers` | data dirs, env, unit, start, wait for ready |
| 06 | `06_verify.yml` | `admin` | ring, etcd and control-plane assertions |
| 07 | `07_observability.yml` | `observability_servers` | telemetry stack |

`dfkv_site.yml` runs all of them in order for a greenfield cluster. Each step is
also a standalone playbook — run it directly to re-apply just that one.

Three playbooks are outside the chain and are never part of a bring-up:
`08_client.yml` (publishes client artifacts to a shared filesystem, which is not
a step in starting a region), `90_upgrade.yml` and `91_uninstall.yml` (lifecycle
actions), and `99_status.yml` (read-only report).

### Two entry points, one command each

Both are idempotent: a re-run against unchanged inputs reports no
changes.

| what | command | phases it runs |
|---|---|---|
| the whole region | `dfkv_site.yml` | 00-07, each against its own group |
| a batch of cache (GPU) nodes | `dfkv_gpu_site.yml` | `prepare` + `release` + `server` |

The first composes imported *playbooks*, because its phases each target a
different group (`etcd_servers`, then `mds_servers`, then `cache_servers`). The
second has a single host set -- `cache_servers` -- so it composes three *roles*
in one play instead, which is both shorter and harder to get wrong.

`05_server.yml` and `08_client.yml` remain as the single-phase entry points, for
re-applying just that step once the release is already staged.

**Two different things are called "client" in this domain, and only one of them
is dfkv's.** The cache nodes are the GPU machines, and their dfkv process is
`dfkv_server` -- a server, in the `cache_servers` group. dfkv's actual client is
the library inside the inference process (`libdfkv.so`, the `dfkv_connector` and
`dfkv_vllm` packages); it is *published* to a shared filesystem rather than
deployed to a node, which is what `08_client.yml` does.

**There is deliberately no host-tuning phase.** The obvious candidates do not
apply: the load-bearing limits (`LimitMEMLOCK`, `LimitNOFILE`, `TimeoutStartSec`,
`OOMScoreAdjust`) are per-service and belong to the units, where they travel
with the service they belong to. `vm.swappiness` in particular is irrelevant,
because the RAM arena is `mlock`ed and locked pages are not reclaimable.

### Why this order

`etcd` is the only authoritative state in the system and must be healthy before
any MDS starts — an MDS that cannot reach etcd exits rather than degrading. The
MDS must be up before any server, because a server's first registration has a
hard 60-second deadline and it exits 1 on expiry; servers do not queue waiting
for it. Telemetry comes last so its first scrape sees a fully-formed cluster
instead of filling the dashboards with startup noise.

## The release model

A release is `dfkv-<version>-linux-x86_64.tar.gz` from
[the DingoCache releases page](https://github.com/dingodb/DingoCache/releases).
The control node has no `gh`, so `dfkv_release` fetches over HTTPS and honours
`dfkv_release_proxy` / `dfkv_release_all_proxy` for networks that need one.

The fetch is gated twice: first against the release's published `SHA256SUMS`,
then against the manifest inside the unpacked tree on the target. The second is
not redundant with the first — one catches a corrupted download, the other a
corrupted unpack.

On the node:

```
/root/dfkv/
├── releases/<version>/     bin/ lib/ python/ integration/ observability/
│                           dfkv_server_start.sh  dfkv_mds_start.sh
│                           dfkv-server.env  dfkv-mds.env  SHA256SUMS
│                           .dfkv-release.json
├── current -> releases/<version>
├── conf/                   dfkv-server.env, dfkv-mds.env  (version-independent)
└── backup/
```

**Upgrading is a symlink flip plus a restart.** `conf/` and the data
directories are version-independent, so neither is rewritten. Rollback is the
same playbook pointed at the previous version — there is no separate rollback
path.

**A release directory is immutable once staged.** The launcher scripts are
`copy`d into each release directory at stage time and never rewritten, and the
unit runs `current/dfkv_server_start.sh`. That is what makes a rollback safe:
flipping `current` back to an older release also restores that release's
launcher, so an older binary is never handed a flag it does not understand.
Re-staging a version with a changed launcher fails rather than quietly
rewriting a directory a rollback depends on.

### The flag gate

Before a staged release becomes activatable, its binary is asked whether it
supports the flags this deployment sets (`dfkv_server_required_flags`). The one
that has actually bitten is `--rdma-recv-chunk-bytes`, which arrived in the
release containing DingoCache PR #359: a deployment that sets a receive-pool
budget against an older artifact gets a server that silently ignores it.

## Upgrading

```bash
# 1. stage. Never restarts anything; always safe to run ahead of the window.
ansible-playbook -i <inv> playbooks/02_release.yml -e dfkv_version=2.29.0

# 2. activate. MDS first (serial 1), then servers in batches.
ansible-playbook -i <inv> playbooks/90_upgrade.yml -e dfkv_version=2.29.0 \
                 -e dfkv_upgrade_batch=4

# 3. roll back the same way
ansible-playbook -i <inv> playbooks/90_upgrade.yml -e dfkv_version=2.28.0
```

Activation per node is: RAM gate → flip `current` → restart → poll the metrics
endpoint until it reports the target version → RAM gate again.

Batch size is about **live clients, not node count**. A ring with no registered
consumers can be taken in one pass; a ring serving inference needs small
batches. Measured on xn01: 47 nodes at `batch=4` with 32 live clients, zero
disconnects.

The RAM gate refuses to restart a server whose RAM tier still holds
acknowledged writes. A missing `dfkv_ram_healthy` metric means the tier is off,
which passes.

> **MDS ordering.** This playbook rolls MDS before servers, following the
> upstream deployment guide: an older MDS does not recognise `kListTopology`, so
> a modern server polling it fails the call and keeps its last-good ring —
> nothing breaks immediately, which is exactly the problem, because the ring
> freezes silently. The fleet tooling this replaces rolled servers first and
> then called `upgrade-mds`, apparently by accident of subcommand ordering.

## Verification

```bash
ansible-playbook -i <inv> playbooks/06_verify.yml
```

Verification asserts against **the ring**, not against the inventory. That
distinction is the whole point: the previous tooling walked `nodes.txt` and
reported a healthy cluster for 13 days while a node that had been removed from
the list — but never disabled — came back on reboot, re-registered, and served
2.7% of the keyspace. It was invisible because it was no longer in the list
being walked.

The assertions:

- every member in the ring reports the target version, RDMA depth and RAM arena
- the ring's member count matches etcd's registration count for that group

A count mismatch is reported as a mismatch and never narrowed to make the
output green. hd02 carries a known hardware-failed node whose gap is
deliberately preserved in both the ring count and the monitoring target count.

The one-line inspection criterion, which must print nothing:

```bash
dfkvctl ring --mds <endpoints> --group <group> | tail -n +3 | grep -v 'ver=<target>'
```

## Telemetry

One stack per region, normally on an MDS node. The upstream
`docker-compose.yml` is already `DFKV_*`-variable driven, so a region's
differences live in a rendered `.env` rather than a re-rendered compose. Only
two things are rendered: `prometheus.yml` (scrape targets are this region's
nodes) and the port bindings (only OTLP needs to be reachable from the GPU
nodes; everything else stays on loopback).

The bundle is content-addressed — `releases/<version>-<hash12>` — so identical
inputs reuse a revision instead of restarting a healthy stack.

Scrape targets are the **declared** node set, not the live ring. A node that has
fallen out of the ring must stay visible in monitoring precisely when it
disappears from the ring; deriving targets from the ring would erase the outage
along with the evidence.

The Grafana admin password lives in a root-only file and is read, never rotated:
a deploy can never silently recreate Grafana with a different password and lock
out every existing session. Rotating it is a separate act that also has to
rotate the Grafana database.

## Client publication

```bash
ansible-playbook -i <inv> playbooks/08_client.yml
```

The library and connector packages are published to the shared filesystem under
an explicit version directory and are **never** exposed through a `current`
symlink. A symlink flip on a lazily-consistent network filesystem (DingoFS,
GPFS) resolves differently on different nodes for a window of seconds; engines
in one ring that load different builds derive different cache identities and
quietly miss each other, which is a correctness problem rather than a
performance one. Pod specs pin `release/<version>/` explicitly.

Publishing is not activation. Cutting a ring over to a new version is a
coordinated restart of every engine instance in that ring, inside one window.

## Driving this from a region inventory

Real clusters are driven from a private inventory repository that sits alongside
this one:

```
~/dfkv/ansible-dfkv        # this repo, public, `git pull` to update
~/dfkv/ansible-dfkv-env    # the region inventory, private
```

```bash
cd ~/dfkv/ansible-dfkv
ansible-playbook -i ../ansible-dfkv-env/<region>/hosts.py \
                 -i ../ansible-dfkv-env/<region>/hosts-mds.yml \
                 playbooks/dfkv_site.yml
```

Two inventory sources are needed because the two halves of a cluster are
discovered differently: cache nodes live in Kubernetes and come from a dynamic
inventory, while MDS and etcd nodes deliberately do not and are static. A run
that omits `hosts-mds.yml` renders `dfkv_mds_endpoints` empty, and every server
fails its first registration.

**Ansible loads `group_vars` only from the inventory source directory and the
playbook directory — not from this repo's `inventory/`.** So each region's
`group_vars/all.yml` must be self-contained: copy `inventory/group_vars/all.yml`
from this repo and override, rather than expecting the two to merge.

## Standalone playbooks

| Playbook | Default target | Purpose |
|---|---|---|
| `01_prepare.yml` | all | packages and directories; re-run safe |
| `02_release.yml` | MDS + cache | stage a release; never restarts |
| `03_etcd.yml` | `etcd_servers` | greenfield etcd only; refuses if already active |
| `04_mds.yml` | `mds_servers` | deploy or reconverge MDS |
| `05_server.yml` | `cache_servers` | deploy or reconverge servers |
| `07_observability.yml` | `observability_servers` | telemetry stack |
| `08_client.yml` | `client_stage` | publish the client tree |
| `06_verify.yml` | `admin` | ring and etcd assertions |
| `90_upgrade.yml` | MDS + cache | rolling upgrade; also the rollback path |
| `99_status.yml` | all | read-only report |

Operation switches, all via `-e`:

| Variable | Effect |
|---|---|
| `dfkv_version` | the release to stage or activate |
| `dfkv_upgrade_batch` | servers per batch (default 8) |
| `target_hosts` | retarget playbooks that accept it |
| `dfkv_release_proxy` / `dfkv_release_all_proxy` | proxy for the control-node fetch |
| `dfkv_release_use_local_tarball` / `dfkv_release_local_tarball` | skip the network |
| `dfkv_release_allow_restage` | deliberately rewrite a staged release |
| `dfkv_etcd_allow_rebootstrap` | bootstrap etcd against a live member |
| `dfkv_client_force` | replace a published client build with different bytes |
| `dfkv_disk_usage_ratio` | fraction of each disk dfkv may take (default 0.50) |
| `dfkv_server_wipe_on_capacity_change` | discard a node's cache so its capacity can change |
| `dfkv_server_serial` | how many nodes to change capacity on at once (default all) |

## Troubleshooting

**`FATAL: no data directories under /mnt/disk*/dfkv2`.** The launcher could not
find any mounted data disk with the configured subdirectory. Check that the
disks are mounted, and that the node has at least one disk above
`dfkv_min_disk_gb` — the selection excludes anything smaller.

**A capacity change is refused.** `dfkv_server_wipe_on_capacity_change` is off and
the derived capacity differs from what the node is running. This is the guard
described under [Capacity and disk selection](#capacity-and-disk-selection):
roll one canary first, confirm it comes back healthy with the expected capacity,
then re-run with the override.

**`FATAL: no IPv4 address on <iface>`.** `dfkv_advertise_iface` names an
interface with no IPv4 address. This is the failure that a missing
`ADV_IFACE_MAP` entry used to cause region-wide, from a generated environment
file that omitted the key.

**A server starts, reports healthy, and is not in the ring.** Check
`--group`: a server joins exactly one group, and a client only sees its own.
`dfkvctl ring --group <other>` will show it sitting in the wrong one.

**The ring reports `members=0` while every server is up and serving.** Check
etcd for a `NOSPACE` alarm before restarting anything. Client registration and
lease keepalives rewrite keys continuously, so the revision counter climbs even
though the key count is stable; at etcd's 2 GiB default this ends in a read-only
backend. The MDS error counters climb and `dfkvctl ring` reports zero, but the
data plane keeps working perfectly — a "phantom" ring loss. The etcd role sets
an 8 GiB quota and periodic compaction to prevent it; for an existing cluster,
`etcdctl compact`, `defrag` and `alarm disarm`.

**A node refuses to start after a version change.** Slab's on-disk format is
tenant-scoped and intentionally incompatible with pre-v3 metadata, so upgrading
a slab node requires a **clean cache directory**. Never start a new version
against an old cache directory in place.

**Failures that are easy to misread:**

- `Error 203/EXEC` from systemd with no AVC log is SELinux refusing to exec from
  a home directory, not a missing file.
- A `uri` task against `/healthz` returning 200 does not mean the MDS can reach
  etcd — `/healthz` is process liveness only, deliberately, so that an etcd
  outage does not become a crash-loop storm. Use `/readyz`.
