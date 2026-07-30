#!/bin/bash
#
# Bash script to download all QuakeJS assets.
#
# Originally by Sean Begley (2017-07-06), which pulled from
# http://content.quakejs.com. That host is offline, so assets now come from the
# GitHub mirror:
#
#   https://github.com/gionko/content.quakejs.com/tree/master/assets
#
# The mirror stores plain pk3s, which is all bin/content.js needs. It walks the
# assets directory at startup, computes each file's crc32 and gzip'd length, and
# serves the result at /assets/manifest.json. Requests arrive as
# assets/<dir>/<crc32>-<name>; content.js verifies the crc against its own
# manifest and then reads the plain file off disk. So there is deliberately no
# manifest.json written here and no crc32-prefixed copies -- generating either
# would be dead weight, and a hand-computed gzip length does not match Node's
# zlib output anyway.
#
# If you ever serve these files from a plain webserver instead of content.js,
# you WILL need a real manifest.json and crc32-prefixed filenames, since nothing
# is left to strip the prefix at request time.
#
# The mirror is fetched as a tarball streamed straight through tar, so the
# archive never lands on disk and gzip's per-member CRC catches a truncated or
# corrupted transfer. Every run re-downloads the whole tree (~260MB); there is
# no incremental update.
#
# USAGE
#   ./get_assets.sh                                  # default mirror, output to .
#   ./get_assets.sh /srv/quake-assets                # alternate output folder
#   ./get_assets.sh /srv/quake-assets gh:owner/repo  # alternate GitHub mirror
#
# Mirror spec: gh:owner/repo[@ref][:subdir]  (ref defaults to master,
# subdir to assets)
#
# Requires: bash, curl, tar

set -uo pipefail

DEFAULT_SOURCE="gh:gionko/content.quakejs.com@master:assets"

output_dir="${1:-.}"
source_spec="${2:-$DEFAULT_SOURCE}"
assets_dir="$output_dir/assets"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }

for tool in curl tar; do
	command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done

spec=$source_spec
case $spec in
	http://*|https://*)
		die "only GitHub mirrors are supported; expected gh:owner/repo[@ref][:subdir], got '$spec'" ;;
esac

spec=${spec#gh:}
subdir="assets"; ref="master"
case $spec in
	*:*) subdir=${spec##*:}; spec=${spec%%:*} ;;
esac
case $spec in
	*@*) ref=${spec##*@}; spec=${spec%%@*} ;;
esac
repo=$spec
[[ $repo == */* ]] || die "expected a GitHub mirror like gh:owner/repo[@ref][:subdir], got '$source_spec'"

# The archive's top level is a single <repo>-<sha>/ directory, so strip that
# plus however many components the requested subdir adds.
strip=1
pattern=
if [ -n "$subdir" ]; then
	strip=$(( 2 + $(printf '%s' "$subdir" | tr -cd '/' | wc -c) ))
	pattern="*/$subdir/*"
fi

mkdir -p "$assets_dir" || die "cannot create $assets_dir"

note "Streaming https://codeload.github.com/$repo/tar.gz/refs/heads/$ref"
# Piped straight into tar, so the archive never hits disk, and only the subdir
# is unpacked -- directly into place, no staging copy. --wildcards is GNU tar;
# bsdtar matches patterns without it, so retry bare if the first form fails.
fetch() { curl -fsSL --retry 3 --retry-delay 2 \
	"https://codeload.github.com/$repo/tar.gz/refs/heads/$ref"; }

if ! fetch | tar xz -C "$assets_dir" --strip-components="$strip" \
		${pattern:+--wildcards "$pattern"} 2>/dev/null
then
	if ! fetch | tar xz -C "$assets_dir" --strip-components="$strip" ${pattern:+"$pattern"}
	then
		die "download or extraction failed"
	fi
fi

# guard against a silently empty unpack, e.g. a bad subdir that matched nothing
find "$assets_dir" -type f -name '*.pk3' | grep -q . \
	|| die "no pk3s unpacked; is '$subdir' correct for $repo@$ref?"

note "Assets in $assets_dir"
note "Done. Serve with:  node bin/content.js   (it builds manifest.json itself)"
