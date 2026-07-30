#!/bin/sh
#
# Dedicated server entrypoint. Baked into the server image as bin/quake.sh.
#
# Changes from the previous version:
#   * `set dedicated 1` -> `+set dedicated 1`. The original was missing the '+',
#     so it was never applied as a console command; the server was relying on
#     server.cfg to set dedicated. Harmless to fix -- +exec still runs afterwards,
#     so server.cfg continues to win where they disagree.
#   * fs_homepath is set explicitly, so everything the engine writes (games.log,
#     generated configs) lands outside the baked-in read-only game data.
#   * The CDN wait loop is now bounded and can be disabled, since compose gates
#     startup on the assets healthcheck instead of spinning here forever.
#   * The CDN address is configurable. It is still the compose service name by
#     default, which is fine for the server (it resolves via compose DNS), but a
#     browser cannot resolve `assets:9000` -- see notes on the public CDN host.

set -e

QUAKE_GAME="${QUAKE_GAME:-baseq3}"
QUAKE_CDN="${QUAKE_CDN:-assets:9000}"
QUAKE_HOMEPATH="${QUAKE_HOMEPATH:-/var/lib/quake}"
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

mkdir -p "${QUAKE_HOMEPATH}"

echo "quake: starting fs_game=${QUAKE_GAME} fs_cdn=${QUAKE_CDN} fs_homepath=${QUAKE_HOMEPATH}" >&2

# Argument order matches the original: fs_game, dedicated, exec server.cfg, then
# fs_cdn last.
exec node build/release-js-js/ioq3ded.js \
  +set fs_homepath "${QUAKE_HOMEPATH}" \
  +set fs_game "${QUAKE_GAME}" \
  +set dedicated 1 \
  +exec server.cfg \
  +set fs_cdn "${QUAKE_CDN}"
