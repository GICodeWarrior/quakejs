#!/usr/bin/env bash
#
# Catalog an asset tree into the layout the QuakeJS engine fetches, so a plain
# static file server can host it.
#
#   catalog-assets.sh <source> <destination>
#
# <source> is an asset root (the directory holding baseq3/, cpma/, ...) and
# <destination> gains an assets/ directory containing:
#
#   assets/manifest.json          [{name, compressed, checksum}, ...]
#   assets/<dir>/<crc>-<name>     every asset, stored under its own checksum
#
# `compressed` is the on-disk size. The client only uses it to total up
# download progress, and we serve these without gzip.
#
set -euo pipefail

[ $# -eq 2 ] || { echo 'usage: catalog-assets.sh <source> <destination>' >&2; exit 1; }
src=$1
dst=$2
mkdir -p "$dst/assets"

( cd "$src" && find . -type f \
    \( -name '*.pk3' -o -name '*.run' -o -name '*.sh' \) -printf '%P\0' ) \
| LC_ALL=C sort -z \
| while IFS= read -r -d '' name; do
      base=$(basename -- "$name")
      dir=$(dirname -- "$name")
      crc=$(cksum -a crc32b -- "$src/$name" | awk '{print $1}')
      size=$(stat -c %s -- "$src/$name")

      install -D -m 0644 -- "$src/$name" "$dst/assets/$dir/$crc-$base"

      jq -cn --arg n "$name" --argjson c "$size" --argjson k "$crc" \
          '{name: $n, compressed: $c, checksum: $k}'
  done \
| jq -s . > "$dst/assets/manifest.json"
