# PeerTube on Railway.
#
# The published image is used as-is; the only addition is socat, which bridges
# Railway's TCP proxy application port onto the RTMP listener, plus a wrapper
# entrypoint that ends by exec'ing PeerTube's own one (so its chown of /data and
# its drop to the `peertube` user still happen).
FROM chocobozzz/peertube:production

USER root

RUN apt-get update \
 && apt-get install -y --no-install-recommends socat \
 && rm -rf /var/lib/apt/lists/*

COPY peertube/entrypoint.sh /usr/local/bin/railway-entrypoint.sh

RUN chmod +x /usr/local/bin/railway-entrypoint.sh \
 && bash -n /usr/local/bin/railway-entrypoint.sh \
 && command -v socat \
 && test -x /usr/local/bin/entrypoint.sh

# Declaring an ENTRYPOINT clears the inherited CMD, so restate it.
ENTRYPOINT [ "/usr/local/bin/railway-entrypoint.sh" ]
CMD [ "node", "dist/server" ]
