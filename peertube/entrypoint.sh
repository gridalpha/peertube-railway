#!/bin/bash
# Railway wrapper around PeerTube's own container entrypoint.
#
# Three things Railway needs that no PeerTube environment variable expresses:
#
#   1. PeerTube keeps admin-editable settings in a second directory (/config)
#      while its media lives in /data. Railway volumes are strictly 1:1, so the
#      local config is moved onto the media volume instead of being lost on
#      every deploy.
#   2. The RTMP ingest URL PeerTube prints is built from `live.rtmp.port`, and
#      there is no separate "public port" setting. Railway's TCP proxy listens
#      on a port it chooses, so the listener is bound on that public port and
#      the proxy's application port is bridged onto it.
#   3. A cross-service `${{...RAILWAY_PUBLIC_DOMAIN}}` reference renders empty
#      until that service owns a deployment, which would leave the object
#      storage base URL as a bare "https://".
#
# Everything else is a plain environment variable and is set on the service.
set -e

log() { echo "[railway-entrypoint] $*"; }

DATA_DIR="${PEERTUBE_DATA_DIR:-/data}"

# --- Admin-editable config, on the volume ----------------------------------
# Anything an administrator changes in Settings is written to
# `local-production.json` under PEERTUBE_LOCAL_CONFIG. The image points that at
# /config, which is a second mount here; keep it on the media volume so a
# redeploy does not silently revert the instance configuration.
export PEERTUBE_LOCAL_CONFIG="${PEERTUBE_LOCAL_CONFIG:-$DATA_DIR/config}"
export NODE_CONFIG_DIR="/app/config:/app/support/docker/production/config:$PEERTUBE_LOCAL_CONFIG"
mkdir -p "$PEERTUBE_LOCAL_CONFIG" "$DATA_DIR/tmp" "$DATA_DIR/tmp-persistent"
chown -R peertube:peertube "$PEERTUBE_LOCAL_CONFIG" || true
log "local config: $PEERTUBE_LOCAL_CONFIG"

# --- Public hostname -------------------------------------------------------
# PeerTube bakes this into every ActivityPub actor and every generated URL, so
# it has to be right on the very first boot.
if [ -z "$PEERTUBE_WEBSERVER_HOSTNAME" ] && [ -n "$RAILWAY_PUBLIC_DOMAIN" ]; then
  export PEERTUBE_WEBSERVER_HOSTNAME="$RAILWAY_PUBLIC_DOMAIN"
fi
log "webserver hostname: ${PEERTUBE_WEBSERVER_HOSTNAME:-<unset>}"

# --- Object storage base URLs ----------------------------------------------
# These point at the media gateway, which signs the reads Railway's managed
# bucket refuses anonymously. A reference that has not resolved yet arrives as
# an empty string or a bare scheme; unset it rather than handing PeerTube a
# hostless URL, so it falls back to the bucket and the next deploy repairs it.
for name in PEERTUBE_OBJECT_STORAGE_WEB_VIDEOS_BASE_URL \
            PEERTUBE_OBJECT_STORAGE_STREAMING_PLAYLISTS_BASE_URL \
            PEERTUBE_OBJECT_STORAGE_CAPTIONS_BASE_URL; do
  eval "value=\${$name-}"
  case "$value" in
    "" | "https://" | "http://" | "https:///" )
      if [ -n "$value" ]; then
        log "WARNING: $name is '$value' — the media gateway domain has not resolved yet"
      fi
      unset "$name"
      ;;
  esac
done

# --- RTMP ingest through Railway's TCP proxy -------------------------------
if [ "$PEERTUBE_LIVE_ENABLED" = "true" ]; then
  app_port="${RAILWAY_TCP_APPLICATION_PORT:-1935}"
  public_port="${RAILWAY_TCP_PROXY_PORT:-}"

  if [ -n "$public_port" ] && [ "$public_port" != "$app_port" ]; then
    export PEERTUBE_LIVE_RTMP_PORT="$public_port"
    log "RTMP bound on $public_port; bridging $app_port -> 127.0.0.1:$public_port"
    socat "TCP4-LISTEN:$app_port,fork,reuseaddr" "TCP4:127.0.0.1:$public_port" &
    socat "TCP6-LISTEN:$app_port,ipv6only=1,fork,reuseaddr" "TCP4:127.0.0.1:$public_port" &
  else
    export PEERTUBE_LIVE_RTMP_PORT="$app_port"
    log "no TCP proxy port injected; RTMP stays on $app_port"
  fi

  if [ -n "$RAILWAY_TCP_PROXY_DOMAIN" ]; then
    export PEERTUBE_LIVE_RTMP_PUBLIC_HOSTNAME="$RAILWAY_TCP_PROXY_DOMAIN"
    log "RTMP public host: $RAILWAY_TCP_PROXY_DOMAIN:$PEERTUBE_LIVE_RTMP_PORT"
  fi
fi

# PeerTube's own entrypoint chowns /data and drops to the peertube user.
exec /usr/local/bin/entrypoint.sh "$@"
