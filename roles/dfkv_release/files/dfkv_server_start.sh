#!/usr/bin/env bash
# Managed by ansible-dfkv. Do not edit on the node.
#
# Staged into a release directory and never rewritten afterwards: the unit runs
# <root>/current/dfkv_server_start.sh, so flipping `current` back to an older
# release restores that release's launcher along with its binary. Editing this
# file on a node is pointless -- the next stage overwrites it, and the next
# release uses the new copy anyway.
#
# The node's own parameters live in <root>/conf/dfkv-server.env, which is
# version-independent on purpose: a release flip swaps the binary without
# touching node-local tuning, and tuning can be changed without staging a
# release. Nothing here is inferred from the hostname.
#
# DRYRUN=1 prints the command line instead of running it.

set -euo pipefail

DST="$(cd "$(dirname "$0")" && pwd)"
ENVDIR="${DFKV_CONF_DIR:-$DST}"
ENVFILE="$ENVDIR/dfkv-server.env"

if [ ! -f "$ENVFILE" ]; then
  echo "FATAL: $ENVFILE not found (DFKV_CONF_DIR=$ENVDIR)" >&2
  exit 1
fi
# shellcheck disable=SC1090
. "$ENVFILE"

: "${GROUP:?dfkv-server.env is missing GROUP}"
: "${MDS:?dfkv-server.env is missing MDS}"
: "${CAP:?dfkv-server.env is missing CAP}"
: "${DISK_SUBDIR:?dfkv-server.env is missing DISK_SUBDIR}"

BIN="$DST/bin/dfkv_server"
[ -x "$BIN" ] || BIN="$DST/dfkv_server"
if [ ! -x "$BIN" ]; then
  echo "FATAL: no dfkv_server binary under $DST" >&2
  exit 1
fi

PORT="${PORT:-28200}"
RDMA_PORT="${RDMA_PORT:-28201}"
WEIGHT="${WEIGHT:-1}"
RDMA_DEV="${RDMA_DEV:-}"
ADV_IFACE="${ADV_IFACE:-}"

if [ -z "$ADV_IFACE" ]; then
  echo "FATAL: ADV_IFACE is empty; peers have no address to reach this node on" >&2
  exit 1
fi

# Data directories. An explicit list wins; otherwise every /mnt/diskN carrying
# the subdirectory. A missing disk is skipped rather than fatal, so a node that
# loses a device degrades instead of refusing to boot -- but a node with no
# usable disk at all is fatal, because a cache node with nowhere to cache is
# worse than one that is down.
DIRS=""
if [ -n "${SERVER_DISKS:-}" ]; then
  for n in $(printf '%s' "$SERVER_DISKS" | tr ',' ' '); do
    d="/mnt/disk${n}/${DISK_SUBDIR}"
    if [ -d "$d" ]; then
      DIRS="${DIRS:+$DIRS,}$d"
    fi
  done
else
  for d in /mnt/disk*/"$DISK_SUBDIR"; do
    if [ -d "$d" ]; then
      DIRS="${DIRS:+$DIRS,}$d"
    fi
  done
fi
if [ -z "$DIRS" ]; then
  echo "FATAL: no data directories under /mnt/disk*/${DISK_SUBDIR}" >&2
  exit 1
fi

# Advertise address is read off the interface rather than stored, so a
# re-addressed node keeps working without an inventory change.
ADV="$(ip -o -4 addr show "$ADV_IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)"
if [ -z "$ADV" ]; then
  echo "FATAL: no IPv4 address on $ADV_IFACE" >&2
  exit 1
fi

# Knobs with no command-line flag at all -- these are the only ones that have to
# travel through the environment. Everything with a flag is passed as a flag
# below, because a flag is visible in `ps` and in the dry run, and because
# dfkv_server's argument parser treats flags as authoritative over the
# environment anyway.
#
# systemd never sees any of this: the unit runs this script, and the script
# sources the env file itself rather than being loaded via EnvironmentFile.
for key in \
  DFKV_SLAB_EVICT_HIGH_PCT \
  DFKV_SLAB_EVICT_LOW_PCT \
  DFKV_SLAB_EVICT_MAX_EXTENTS_PER_TICK \
  DFKV_RDMA_RECV_CHUNK_IDLE_MS \
  DFKV_RAM_ACK_HIGH_WATERMARK_PCT \
  DFKV_PUT_ACK_MODE
do
  if [ -n "${!key:-}" ]; then
    export "${key?}"
  fi
done

set -- "$BIN" \
  --dir "$DIRS" \
  --cap "$CAP" \
  --port "$PORT" \
  --rdma-port "$RDMA_PORT" \
  --mds "$MDS" \
  --group "$GROUP" \
  --id "$(hostname)" \
  --advertise "${ADV}:${RDMA_PORT}" \
  --weight "$WEIGHT"

# Optional flags are appended with `if`, not `[ -n ] && ...`. Under `set -e` a
# trailing `[ -n "$x" ] && append` evaluates false and takes the whole script
# down with it -- which is a silent no-start on some nodes and not others.
if [ -n "$RDMA_DEV" ]; then set -- "$@" --rdma-dev "$RDMA_DEV"; fi
if [ -n "${METRICS_PORT:-}" ]; then set -- "$@" --metrics-port "$METRICS_PORT"; fi
if [ -n "${METRICS_BIND:-}" ]; then set -- "$@" --metrics-bind "$METRICS_BIND"; fi
if [ -n "${STORE_ENGINE:-}" ]; then set -- "$@" --store-engine "$STORE_ENGINE"; fi
if [ -n "${SLAB_WRITE:-}" ]; then set -- "$@" --slab-write "$SLAB_WRITE"; fi
if [ -n "${SLAB_GRANULARITY:-}" ]; then set -- "$@" --slab-granularity "$SLAB_GRANULARITY"; fi
if [ -n "${RDMA_DEPTH:-}" ]; then set -- "$@" --rdma-depth "$RDMA_DEPTH"; fi
if [ -n "${RDMA_NUMA:-}" ]; then set -- "$@" --rdma-numa "$RDMA_NUMA"; fi
if [ -n "${RDMA_RECV_SEGMENT_SIZE:-}" ]; then set -- "$@" --rdma-recv-segment-size "$RDMA_RECV_SEGMENT_SIZE"; fi
if [ -n "${RDMA_RECV_CHUNK_BYTES:-}" ]; then set -- "$@" --rdma-recv-chunk-bytes "$RDMA_RECV_CHUNK_BYTES"; fi
if [ -n "${MAX_MSG:-}" ]; then set -- "$@" --max-msg "$MAX_MSG"; fi
if [ -n "${RAM_TIER:-}" ]; then set -- "$@" --ram-tier "$RAM_TIER"; fi
if [ -n "${RAM_TIER_BYTES:-}" ]; then set -- "$@" --ram-tier-bytes "$RAM_TIER_BYTES"; fi
if [ -n "${RAM_TIER_SHARDS:-}" ]; then set -- "$@" --ram-tier-shards "$RAM_TIER_SHARDS"; fi
if [ -n "${RAM_WRITE_MODE:-}" ]; then set -- "$@" --ram-write-mode "$RAM_WRITE_MODE"; fi
if [ -n "${DISK_HASH_WEIGHT:-}" ]; then set -- "$@" --disk-hash-weight "$DISK_HASH_WEIGHT"; fi
if [ -n "${READ_COALESCE:-}" ]; then set -- "$@" --read-coalesce "$READ_COALESCE"; fi
if [ -n "${PUT_INFLIGHT_LIMIT:-}" ]; then set -- "$@" --put-inflight-limit "$PUT_INFLIGHT_LIMIT"; fi
if [ -n "${MDS_REGISTRATION_TIMEOUT_MS:-}" ]; then set -- "$@" --mds-registration-timeout-ms "$MDS_REGISTRATION_TIMEOUT_MS"; fi
if [ -n "${LOG:-}" ]; then set -- "$@" --log "$LOG"; fi

if [ "${DRYRUN:-}" = "1" ]; then
  printf '%s\n' "$*"
  exit 0
fi

exec "$@"
