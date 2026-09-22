#!/usr/bin/env bash
# Managed by ansible-dfkv. Do not edit on the node.
#
# See dfkv_server_start.sh for why this is staged per release rather than kept
# at a single shared path.
#
# DRYRUN=1 prints the command line instead of running it.

set -euo pipefail

DST="$(cd "$(dirname "$0")" && pwd)"
ENVDIR="${DFKV_CONF_DIR:-$DST}"
ENVFILE="$ENVDIR/dfkv-mds.env"

if [ ! -f "$ENVFILE" ]; then
  echo "FATAL: $ENVFILE not found (DFKV_CONF_DIR=$ENVDIR)" >&2
  exit 1
fi
# shellcheck disable=SC1090
. "$ENVFILE"

: "${LISTEN:?dfkv-mds.env is missing LISTEN}"
: "${ETCD:?dfkv-mds.env is missing ETCD}"

# dfkv_mds prefixes the scheme itself. An endpoint written as "http://host:port"
# here becomes "http://http://host:port" and every etcd call fails, which looks
# like an etcd outage rather than a typo. Catch it here where the message is
# unambiguous.
case "$ETCD" in
  *://*)
    echo "FATAL: ETCD must be host:port without a scheme, got '$ETCD'" >&2
    exit 1
    ;;
esac

BIN="$DST/bin/dfkv_mds"
[ -x "$BIN" ] || BIN="$DST/dfkv_mds"
if [ ! -x "$BIN" ]; then
  echo "FATAL: no dfkv_mds binary under $DST" >&2
  exit 1
fi

if [ -n "${DFKV_MDS_ACCEPT_LEGACY:-}" ]; then
  export DFKV_MDS_ACCEPT_LEGACY
fi
if [ -n "${DFKV_MDS_ETCD_PROBE_MS:-}" ]; then
  export DFKV_MDS_ETCD_PROBE_MS
fi

set -- "$BIN" --listen "$LISTEN" --etcd "$ETCD"

if [ -n "${METRICS_PORT:-}" ]; then set -- "$@" --metrics-port "$METRICS_PORT"; fi
if [ -n "${METRICS_BIND:-}" ]; then set -- "$@" --metrics-bind "$METRICS_BIND"; fi
if [ -n "${LOG:-}" ]; then set -- "$@" --log "$LOG"; fi

if [ "${DRYRUN:-}" = "1" ]; then
  printf '%s\n' "$*"
  exit 0
fi

exec "$@"
