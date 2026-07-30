#!/bin/sh
#
# Build a plain-named Quake base/ tree from a crc32-prefixed quakejs asset tree.
#
#   derive-base.sh <asset root> <output base dir>
#
# get_assets.sh mirrors the content server's URL layout, so files land as
#   <asset root>/<dir>/<crc32>-<name>
# which is what bin/content.js wants: the client derives request URLs from the
# manifest, so the crc prefix simply becomes part of the basename it asks for.
#
# The Quake filesystem, however, opens paths literally -- it wants
#   base/baseq3/pak0.pk3
# This walks the manifest and hardlinks each asset into place under its real
# name, so the dedicated server can be shipped with its game data baked in
# instead of downloading it from the CDN on first run.
#
# Hardlinks keep this stage cheap; COPY --from materialises them as real files in
# the consuming image anyway.

set -e

src="${1:?usage: derive-base.sh <asset root> <output base dir>}"
dst="${2:?usage: derive-base.sh <asset root> <output base dir>}"
manifest="${src}/manifest.json"

[ -f "$manifest" ] || { echo "derive-base: no manifest at $manifest" >&2; exit 1; }

linked=0
missing=0

# Tab-separated so names containing spaces survive.
jq -r '.[] | [.name, (.checksum|tostring)] | @tsv' "$manifest" > /tmp/derive-base.list

while IFS="$(printf '\t')" read -r name checksum; do
  [ -n "$name" ] || continue

  dir=$(dirname "$name")
  file=$(basename "$name")

  # Prefer the crc-prefixed copy; tolerate an already-plain tree.
  found=""
  for candidate in "${src}/${dir}/${checksum}-${file}" "${src}/${dir}/${file}"; do
    if [ -f "$candidate" ]; then found="$candidate"; break; fi
  done

  if [ -z "$found" ]; then
    echo "derive-base: WARNING: no local file for manifest entry ${name}" >&2
    missing=$((missing + 1))
    continue
  fi

  mkdir -p "${dst}/${dir}"
  ln -f "$found" "${dst}/${dir}/${file}" 2>/dev/null \
    || cp -p "$found" "${dst}/${dir}/${file}"
  linked=$((linked + 1))
done < /tmp/derive-base.list

rm -f /tmp/derive-base.list

echo "derive-base: ${linked} assets placed under ${dst} (${missing} missing)"

# A handful of missing entries is survivable; a mostly-empty tree is not.
[ "$linked" -gt 0 ] || { echo "derive-base: nothing placed" >&2; exit 1; }
