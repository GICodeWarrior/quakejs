#!/bin/sh

# Dedicated server entrypoint.

set -e

QUAKE_GAME="${QUAKE_GAME:-baseq3}"
QUAKE_CDN="${QUAKE_CDN:-web:80}"

echo "quake: starting fs_game=${QUAKE_GAME} fs_cdn=${QUAKE_CDN}" >&2

# +exec runs after the +set flags, so server.cfg wins where they disagree.
exec node build/release-js-js/ioq3ded.js \
  +set fs_game "${QUAKE_GAME}" \
  +set dedicated 1 \
  +exec server.cfg \
  +set fs_cdn "${QUAKE_CDN}"
