# Public media gateway for PeerTube's object storage.
#
# Dependency-free: Node's own crypto and fetch do the SigV4 signing and the
# streaming, so there is nothing to install and nothing to keep patched.
FROM node:24-alpine

WORKDIR /srv
COPY media-gateway/server.js /srv/server.js
RUN node --check /srv/server.js

USER node
CMD ["node", "/srv/server.js"]
