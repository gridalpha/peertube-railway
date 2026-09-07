# PeerTube remote transcoding runner.
#
# `@peertube/peertube-runner` is a CLI, not a server image, so this is the whole
# packaging: Node 22+, ffmpeg/ffprobe 4.3+, and the entrypoint that registers it
# with the instance before starting the job loop.
FROM node:22-bookworm-slim

# node:*-slim purges ca-certificates at the end of its own build, which breaks
# every non-Node HTTPS call in the image — curl's included, and this entrypoint
# is built on curl.
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl jq ffmpeg \
 && rm -rf /var/lib/apt/lists/*
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

RUN npm install -g @peertube/peertube-runner@0.6.0 \
 && peertube-runner --version \
 && ffmpeg -version | head -1 \
 && ffprobe -version | head -1

WORKDIR /srv
COPY runner/entrypoint.sh /usr/local/bin/runner-entrypoint.sh
COPY runner/health.mjs /srv/health.mjs

RUN chmod +x /usr/local/bin/runner-entrypoint.sh \
 && bash -n /usr/local/bin/runner-entrypoint.sh \
 && node --check /srv/health.mjs

# Railway mounts the volume here; the runner keeps its registration and its
# transcoding scratch space under $HOME.
ENV HOME=/runner
RUN mkdir -p /runner

CMD [ "/usr/local/bin/runner-entrypoint.sh" ]
