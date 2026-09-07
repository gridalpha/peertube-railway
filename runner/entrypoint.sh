#!/bin/bash
# PeerTube remote transcoding runner.
#
# With `transcoding.remote_runners.enabled`, PeerTube stops transcoding locally
# and waits for a registered runner to claim each job. A runner registers with a
# *registration token*, which only exists once the instance is installed and is
# readable only by an administrator — so no Railway variable can carry it and
# there is nothing for a deployer to wire up. This entrypoint fetches one from
# the instance's own API at boot, registers, and then runs the server.
#
# The registration is stored under $HOME on the volume, so a redeploy re-uses
# the runner PeerTube already knows rather than filling the admin's runner list
# with dead registrations.
#
# Deliberately no `set -e`: every step here is a retry loop against a service
# that has no deployment ordering, and a single failed probe must not end the
# container.

log() { echo "[runner] $*"; }

: "${PEERTUBE_URL:?PEERTUBE_URL is required}"
: "${PEERTUBE_ADMIN_PASSWORD:?PEERTUBE_ADMIN_PASSWORD is required}"
: "${PEERTUBE_ADMIN_USERNAME:=root}"
: "${RUNNER_NAME:=railway-runner}"
: "${HOME:=/runner}"
export HOME

# A trailing slash breaks the URL comparison peertube-runner does internally.
PEERTUBE_URL="${PEERTUBE_URL%/}"

mkdir -p "$HOME/.config" "$HOME/.cache" "$HOME/.local/share"

write_config() {
  dir="$HOME/.config/peertube-runner-nodejs/default"
  mkdir -p "$dir"
  if [ -f "$dir/config.toml" ]; then
    return 0
  fi

  # Railway reports the host's 48 cores through nproc, not the container's
  # quota, so ffmpeg is sized from the cgroup instead.
  cpus=2
  if [ -r /sys/fs/cgroup/cpu.max ]; then
    read -r quota period < /sys/fs/cgroup/cpu.max
    if [ "$quota" != "max" ] && [ -n "$period" ] && [ "$period" -gt 0 ] 2>/dev/null; then
      cpus=$(( quota / period ))
    fi
  fi
  if [ "$cpus" -lt 1 ]; then
    cpus=1
  fi
  log "sizing ffmpeg for ${cpus} cpu(s)"

  {
    echo '[jobs]'
    echo 'concurrency = 1'
    echo ''
    echo '[ffmpeg]'
    echo "threads = ${cpus}"
    echo 'nice = 20'
  } > "$dir/config.toml"
}

is_registered() {
  peertube-runner list-registered 2>/dev/null | grep -qF "$PEERTUBE_URL"
}

api_token() {
  clients=$(curl -fsS "$PEERTUBE_URL/api/v1/oauth-clients/local")
  if [ -z "$clients" ]; then
    return 1
  fi

  client_id=$(printf '%s' "$clients" | jq -r '.client_id // empty')
  client_secret=$(printf '%s' "$clients" | jq -r '.client_secret // empty')
  if [ -z "$client_id" ] || [ -z "$client_secret" ]; then
    return 1
  fi

  curl -fsS -X POST "$PEERTUBE_URL/api/v1/users/token" \
    --data-urlencode "client_id=$client_id" \
    --data-urlencode "client_secret=$client_secret" \
    --data-urlencode "grant_type=password" \
    --data-urlencode "response_type=code" \
    --data-urlencode "username=$PEERTUBE_ADMIN_USERNAME" \
    --data-urlencode "password=$PEERTUBE_ADMIN_PASSWORD" \
    | jq -r '.access_token // empty'
}

registration_token() {
  token="$1"

  existing=$(curl -fsS -H "Authorization: Bearer $token" \
    "$PEERTUBE_URL/api/v1/runners/registration-tokens?start=0&count=1&sort=-createdAt" \
    | jq -r '.data[0].registrationToken // empty')
  if [ -n "$existing" ]; then
    printf '%s' "$existing"
    return 0
  fi

  curl -fsS -X POST -H "Authorization: Bearer $token" \
    "$PEERTUBE_URL/api/v1/runners/registration-tokens/generate" \
    | jq -r '.registrationToken // empty'
}

register() {
  token=$(api_token)
  if [ -z "$token" ]; then
    log "could not obtain an admin token"
    return 1
  fi

  rtoken=$(registration_token "$token")
  if [ -z "$rtoken" ]; then
    log "could not obtain a runner registration token"
    return 1
  fi

  peertube-runner register \
    --url "$PEERTUBE_URL" \
    --registration-token "$rtoken" \
    --runner-name "$RUNNER_NAME"
}

write_config

# `register` and `list-registered` are not standalone commands: they are RPCs to
# a *running* `peertube-runner server` over a unix socket in
# $HOME/.local/share/peertube-runner-nodejs/default/. Starting the server first
# and registering against it is the only order that works — the other way round
# fails with `connect ENOENT …/peertube-runner.sock`.
peertube-runner server &
RUNNER_PID=$!
echo "$RUNNER_PID" > /tmp/runner.pid

# The runner serves no HTTP of its own, so without this a crash-looping worker
# would report SUCCESS forever.
node /srv/health.mjs &

trap 'kill -TERM "$RUNNER_PID" 2>/dev/null' TERM INT

RUNNER_SOCK="$HOME/.local/share/peertube-runner-nodejs/default/peertube-runner.sock"
i=0
while [ "$i" -lt 60 ]; do
  if [ -S "$RUNNER_SOCK" ]; then
    break
  fi
  i=$(( i + 1 ))
  sleep 1
done
if [ ! -S "$RUNNER_SOCK" ]; then
  log "ERROR: runner server did not open its control socket"
fi

if is_registered; then
  log "already registered with $PEERTUBE_URL"
else
  log "waiting for $PEERTUBE_URL"
  # No service ordering, and PeerTube's first boot runs its migrations, so this
  # can legitimately take minutes.
  i=0
  while [ "$i" -lt 90 ]; do
    if curl -fsS -o /dev/null "$PEERTUBE_URL/api/v1/config"; then
      break
    fi
    i=$(( i + 1 ))
    sleep 10
  done

  i=0
  while [ "$i" -lt 30 ]; do
    if register; then
      log "registered as $RUNNER_NAME"
      break
    fi
    i=$(( i + 1 ))
    log "registration attempt $i failed; retrying in 20s"
    sleep 20
  done
fi

if ! is_registered; then
  log "ERROR: not registered with $PEERTUBE_URL — VOD transcoding jobs will stay pending"
fi

wait "$RUNNER_PID"
