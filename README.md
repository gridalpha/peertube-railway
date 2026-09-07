# peertube-railway

Deployment wrapper that runs [PeerTube](https://joinpeertube.org) on
[Railway](https://railway.com) — federated, ActivityPub-native video hosting
with a real transcoding worker tier and object storage.

One repository backs three services. Each Railway service selects its
Dockerfile with `RAILWAY_DOCKERFILE_PATH`, so every build keeps the repository
root as its build context.

| Directory | Service | Purpose |
|---|---|---|
| `peertube/` | `peertube` | The published `chocobozzz/peertube:production` image plus `socat` and a wrapper entrypoint |
| `media-gateway/` | `media` | Signs anonymous reads of the public video prefixes in Railway's managed bucket |
| `runner/` | `runner` | `@peertube/peertube-runner`, registered with the instance at boot |

## Why a wrapper at all

Three things PeerTube needs on Railway that no environment variable expresses.

**Admin settings live on a second mount.** PeerTube writes everything an
administrator changes in the web UI into `local-production.json` under
`PEERTUBE_LOCAL_CONFIG`, which the image points at `/config` — a mount separate
from `/data`. Railway volumes are strictly one per service, so the entrypoint
moves the local config onto the media volume. Without it, every settings change
is reverted by the next deploy.

**The RTMP ingest URL has no public-port setting.** PeerTube builds the URL it
shows a streamer from `live.rtmp.port`, and Railway's TCP proxy listens on a
port it chooses rather than the one the container binds. The entrypoint binds
the RTMP listener on the proxy's *public* port and bridges the application port
onto it with `socat`, so the URL PeerTube prints is the one that works. Both
values are injected per deployment, so this re-derives itself in any project.

**Public videos are a plain object-storage URL.** PeerTube proxies *private*
videos itself but hands the browser a direct bucket URL for public ones.
Railway's managed object storage implements neither anonymous read nor
`PutBucketPolicy`, so the media gateway is the public half: it signs GET/HEAD
for `web-videos/`, `streaming-playlists/` and `captions/` with SigV4 and streams
the object back. Nothing else in the bucket is reachable through it — in
particular not `user-exports/` or `original-video-files/`, which PeerTube serves
itself through its own presigned URLs.

## The runner

`transcoding.remote_runners.enabled` makes PeerTube stop transcoding locally and
wait for a registered runner. A runner registers with a *registration token*,
which exists only after the instance is installed and is readable only by an
administrator — so it cannot be a Railway variable and cannot be a manual step
in a template. The runner's entrypoint waits for the instance, obtains an admin
token through PeerTube's own OAuth endpoint, reads or generates a registration
token, and registers itself. The result is stored under `$HOME` on the runner's
volume, so a redeploy re-uses the existing registration instead of leaving a
dead one behind in the admin's runner list.

Live transcoding stays local on the web service, where the latency is lower and
where an unavailable runner cannot interrupt a stream in progress.

## Configuration

Everything is a `PEERTUBE_*` environment variable, mapped onto PeerTube's config
tree by
[`custom-environment-variables.yaml`](https://github.com/Chocobozzz/PeerTube/blob/master/support/docker/production/config/custom-environment-variables.yaml).
The deployment's own variable list is documented in the Railway template.

Video import from third-party sites (`PEERTUBE_IMPORT_VIDEOS_HTTP`), torrent and
magnet import (`PEERTUBE_IMPORT_VIDEOS_TORRENT`), channel synchronisation and
video redundancy are all left at PeerTube's own default of **off**, and the
BitTorrent tracker is left **private**, so the instance seeds only its own
videos.

## Licence

PeerTube is AGPL-3.0. This repository only packages it for Railway.
