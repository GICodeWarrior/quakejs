#!/bin/sh
#
# Dedicated server entrypoint. Baked into the server image as bin/quake.sh.
#
# fs_homepath is deliberately not set: the engine resolves it relative to the
# working directory, so an absolute path fails at startup. See CONTAINERS.md.
#
# QUAKE_CDN defaults to the compose service name, which resolves via compose DNS
# for the server. The browser client derives its own CDN address from the page
# it was served from -- see CONTAINERS.md.

set -e

QUAKE_GAME="${QUAKE_GAME:-baseq3}"
QUAKE_CDN="${QUAKE_CDN:-assets:9000}"
# compose already gates startup on the assets healthcheck; this is a bounded
# fallback for running the image outside compose.
QUAKE_WAIT_FOR_CDN="${QUAKE_WAIT_FOR_CDN:-1}"
QUAKE_WAIT_TIMEOUT="${QUAKE_WAIT_TIMEOUT:-120}"

if [ "$QUAKE_WAIT_FOR_CDN" = "1" ]; then
  waited=0
  while ! curl -fsS -o /dev/null "http://${QUAKE_CDN}/assets/manifest.json"; do
    if [ "$waited" -ge "$QUAKE_WAIT_TIMEOUT" ]; then
      echo "quake: asset server ${QUAKE_CDN} not reachable after ${QUAKE_WAIT_TIMEOUT}s" >&2
      exit 1
    fi
    echo "quake: waiting on asset server ${QUAKE_CDN} (${waited}s)" >&2
    sleep 1
    waited=$((waited + 1))
  done
fi

echo "quake: starting fs_game=${QUAKE_GAME} fs_cdn=${QUAKE_CDN}" >&2

# +exec runs after the +set flags, so server.cfg wins where they disagree.
exec node build/release-js-js/ioq3ded.js \
  +set fs_game "${QUAKE_GAME}" \
  +set dedicated 1 \
  +exec server.cfg \
  +set fs_cdn "${QUAKE_CDN}"
