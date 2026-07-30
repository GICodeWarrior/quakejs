# syntax=docker/dockerfile:1.7
#
# Builds everything from the local checkout and produces three self-contained
# runtime images. No host build steps, no bind mounts.
#
# IMPORTANT: no build step here writes to the working tree. Docker copies the
# context into the image, and every modification (the gram.c touch, the pak
# staging, the tsc output) happens to that copy.
#
# Build targets:
#   web       - static client (nginx): index.html + ioquake3.js + shenanigans
#   server    - dedicated server (ioq3ded.js) + game data
#   assets    - quakejs content server (bin/content.js) + asset tree
#   paks      - scratch image containing just pak100.pk3 and pak101.pk3, for
#               `--output type=local` extraction in CI
#   toolchain - the emscripten/LLVM toolchain on its own, for pushing to a
#               registry so it need not be rebuilt
#
#   docker compose build          # or: docker build --target server -t ... .
#
# Development incrementality comes from the cache mounts in quake-build below;
# see compose.dev.yml for the watch/rebuild loop.

# Which image the compile stages build FROM.
#
# The default, `toolchain`, is the name of a stage defined in this file, so the
# toolchain is built locally on demand and `docker compose up` works from a fresh
# checkout with no separate step. Override it with a registry reference (see the
# toolchain section below) to skip building the toolchain entirely:
#
#   TOOLCHAIN_IMAGE=ghcr.io/<owner>/quakejs/toolchain:main docker compose build
#
ARG TOOLCHAIN_IMAGE=toolchain

# ===========================================================================
# TOOLCHAIN: emscripten-fastcomp (LLVM fork) + emscripten 1.13.2, plus every
# build tool the ioq3 build needs.
#
# These stages live here rather than in a separate file so that the default value
# of TOOLCHAIN_IMAGE above resolves to the `toolchain` stage below, and a plain
# `docker compose up` works with no pre-build step.
#
# This is an expensive, rarely-changing build (a full LLVM compile) that depends
# on nothing in this repository. Once you are ready to stop rebuilding it, build
# and push it on its own:
#
#   docker build --target toolchain -t ghcr.io/<owner>/quakejs/toolchain:main .
#   docker push ghcr.io/<owner>/quakejs/toolchain:main
#
# then set TOOLCHAIN_IMAGE to that reference. The stages below are then outside
# the build graph and are never executed.
#
# Debian 11 ("bullseye") is required because it is the last release shipping
# python2, which emscripten 1.13.2 needs. Bullseye LTS ends 2026-08; when the
# mirrors move the packages to the archive, uncomment the sources.list rewrite
# below. Pushing the built image is the real mitigation.
# ===========================================================================

FROM debian:11 AS toolchain-prepare

ARG EMSCRIPTEN_VERSION=1.13.2
ENV EMSCRIPTEN_VERSION=${EMSCRIPTEN_VERSION}

# Uncomment when bullseye leaves the primary mirrors:
# RUN sed -i -e 's|deb.debian.org|archive.debian.org|g' \
#            -e '/security.debian.org/d' /etc/apt/sources.list

# Everything the LLVM build needs. Kept in one layer so the package index and
# the install can never drift apart.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates wget curl cmake python2 git clang make bison groff \
    && rm -rf /var/lib/apt/lists/*

# emscripten 1.13.2 is a python2 program.
RUN update-alternatives --install /usr/bin/python python /usr/bin/python2 0

# emscripten-fastcomp is a fork of LLVM from early in emscripten's life. Recent
# emscripten releases don't need it (the changes were upstreamed into LLVM), but
# 1.13.2 does.
RUN wget -qO- https://github.com/Forklifts-For-Great-Justice/emscripten-fastcomp/archive/refs/tags/${EMSCRIPTEN_VERSION}.tar.gz \
      | tar -zx -C /tmp

# The matching clang fork. For 1.13.x clang must live in <srcdir>/tools/clang or
# the build fails looking for "../../Makefile". (Newer versions want it in the
# parent directory instead.)
RUN mkdir /tmp/clang \
 && wget -qO- https://github.com/Forklifts-For-Great-Justice/emscripten-fastcomp-clang/archive/refs/tags/${EMSCRIPTEN_VERSION}.tar.gz \
      | tar -zx --strip-components 1 -C /tmp/clang

# Upstream typo in a CMakeLists dependency entry.
RUN sed -i -e 's/intinsics/intrinsics/' \
      /tmp/emscripten-fastcomp-*/lib/Bitcode/NaCl/Writer/CMakeLists.txt

WORKDIR /tmp/emscripten-fastcomp-${EMSCRIPTEN_VERSION}
RUN mkdir -p ./tools && mv /tmp/clang tools/clang

# 1.13.x still uses ./configure; cmake support came later.
RUN ./configure \
      --with-clang-srcdir=./tools/clang \
      --enable-cxx11 \
      --enable-targets=js,x86_64 \
      CFLAGS=-Wno-everything \
      CXXFLAGS=-Wno-everything


FROM toolchain-prepare AS toolchain-compile

# Separate layer so a failed/interrupted compile doesn't re-run ./configure.
ARG TOOLCHAIN_MAKE_JOBS=12
RUN make -j${TOOLCHAIN_MAKE_JOBS}

RUN make install DESTDIR=/opt/llvm

# The emscripten frontend itself (python2 scripts, no compilation).
RUN mkdir /opt/emscripten \
 && wget -qO- https://github.com/emscripten-core/emscripten/archive/refs/tags/${EMSCRIPTEN_VERSION}.tar.gz \
      | tar -zx --strip-components=1 -C /opt/emscripten


# ---------------------------------------------------------------------------
# Final toolchain image: the built toolchain plus the tools needed to compile
# ioq3. Deliberately does NOT contain any ioq3 source -- the old
# dev/Dockerfile.quake cloned ioq3 from GitHub here, which is now redundant
# because the local ./ioq3 tree is authoritative.
# ---------------------------------------------------------------------------
FROM debian:11 AS toolchain

ARG EMSCRIPTEN_VERSION=1.13.2
ENV EMSCRIPTEN_VERSION=${EMSCRIPTEN_VERSION}

# build-essential is required and easy to miss: the ioq3 Makefile hardcodes
# TOOLS_CC = gcc and builds the QVM toolchain (q3lcc, q3rcc, q3cpp, q3asm) with
# the NATIVE compiler, not emcc. Those tools then compile the .qvm files.
#
# dev/Dockerfile.quake never named it because it used a plain `apt-get install`:
# Debian's npm Depends on node-gyp, which Recommends build-essential, so gcc
# arrived transitively. Adding --no-install-recommends silently removed it and the
# build failed at 'TOOLS_CC code/tools/lcc/etc/lcc.c: gcc: No such file or
# directory'. Depending on a recommend of a dependency is not something to rely
# on, so it is named explicitly here.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates build-essential nodejs npm git python2 make bison curl \
    && rm -rf /var/lib/apt/lists/*

RUN update-alternatives --install /usr/bin/python python /usr/bin/python2 0

COPY --from=toolchain-compile /opt/llvm /opt/llvm
COPY --from=toolchain-compile /opt/emscripten /opt/emscripten

# Consumed by dev/build-quake.sh.
ENV LLVM=/opt/llvm/usr/local/bin
ENV EMSCRIPTEN=/opt/emscripten

# Fail early and loudly if the toolchain didn't actually land. gcc is included
# because the QVM tools need it and its absence otherwise shows up minutes into a
# compile rather than here.
RUN test -x "${LLVM}/clang" \
 && test -x "${EMSCRIPTEN}/emcc" \
 && test -x "${EMSCRIPTEN}/emmake" \
 && command -v gcc > /dev/null \
 && command -v bison > /dev/null


# ===========================================================================
# quake-build -- compile ioq3 to JavaScript from the ./ioq3 submodule.
#
# This is the only slow, frequently-invalidated stage, so instruction order
# matters: everything invariant happens before any source is copied.
# ===========================================================================
FROM ${TOOLCHAIN_IMAGE} AS quake-build

WORKDIR /opt/ioq3

# ioq3ded.js requires ws at runtime. Debian's node-ws is far too new to work with
# this vintage of emscripten's socket shim, hence the pinned ancient version.
# Installed before the source copy so it is never reinstalled.
RUN --mount=type=cache,target=/root/.npm,sharing=locked \
    mkdir -p node_modules && npm install ws@0.4.29

# Let emscripten do its first-run config generation (writes ~/.emscripten).
RUN PATH=${LLVM}:$PATH ${EMSCRIPTEN}/emmake --generate-config

# --- source copy: everything below is invalidated by an ioq3 edit ---
#
# The whole submodule, not just Makefile and code/: code/ui/ui_shared.h includes
# "../../ui/menudef.h", so the top-level ui/ directory is required too. See
# CONTAINERS.md for why a partial copy is not worth attempting.
#
# .dockerignore keeps ioq3/.git, ioq3/build/, and ioq3/node_modules/ out.
# node_modules must be excluded because the ws install above lives at
# /opt/ioq3/node_modules and this COPY merges into that directory.
COPY ioq3/ ./

# dev/patch-quake.sh is deliberately NOT run: the pinned submodule already
# carries its edits, in a hand-curated form that differs from what the script
# generates, so re-running it would corrupt the tree. See the header of
# dev/patch-quake.sh for the specific divergences.
#
# Assert instead that the tree is in the state the build expects, so bumping the
# submodule to an unpatched commit fails here rather than as a broken link hours
# later. The console-export patterns are quoted to distinguish the prefixed
# '_Con_ToggleConsole_f' in the Makefile from the bare name in SYSC__deps.
RUN set -e; \
    require() { \
      grep -qF "$2" "$1" || { \
        echo "ioq3 tree is missing an expected patch: $3" >&2; \
        echo "  file: $1" >&2; \
        echo "  See dev/patch-quake.sh -- the submodule is normally pre-patched." >&2; \
        exit 1; \
      }; \
    }; \
    require Makefile 'INVOKE_RUN=1 -s LINKABLE=1' 'server LINKABLE=1'; \
    require Makefile 'INVOKE_RUN=0 -s LINKABLE=1' 'client LINKABLE=1'; \
    require Makefile "'_Con_ToggleConsole_f'" 'console export in EXPORTED_FUNCTIONS'; \
    require code/sys/sys_common.js "'Con_ToggleConsole_f'" 'console export in SYSC__deps'; \
    require code/sys/sys_node.js 'PromptEULA: function (callback) { return callback();' 'EULA short-circuit'

# A plain git clone gives every file effectively the same mtime, so make thinks
# gram.y is newer than the checked-in gram.c and tries to regenerate it -- which
# fails, because this bison/yacc can't process that file. Touching the generated
# file makes it unambiguously newer. This applies only to the in-image copy.
RUN touch code/tools/lcc/lburg/gram.c

# The build itself.
#
# Two cache mounts make development incremental:
#   /opt/ioq3/build          - object files; this is what lets make do a partial
#                              rebuild instead of recompiling the world
#   /root/.emscripten_cache  - emscripten's compiled libc/ports
#
# CRITICAL: cache mounts are NOT part of the image. Anything left in build/ when
# this RUN exits is gone. The artifacts must therefore be copied out to a real
# path (/out) inside this same RUN, which is also where the correctness checks
# on the build output live.
COPY dev/build-quake.sh /tmp/
ARG MAKE_JOBS=12
RUN --mount=type=cache,target=/opt/ioq3/build,sharing=locked \
    --mount=type=cache,target=/root/.emscripten_cache,sharing=locked \
    env MAKE_JOBS=${MAKE_JOBS} sh /tmp/build-quake.sh \
 && test -f build/release-js-js/ioq3ded.js \
 && test -f build/release-js-js/ioquake3.js \
 && test -d build/release-js-js/baseq3/vm \
 && mkdir -p /out/baseq3 \
 && cp build/release-js-js/ioq3ded.js  /out/ioq3ded.js \
 && cp build/release-js-js/ioquake3.js /out/ioquake3.js \
 && cp -a build/release-js-js/baseq3/vm /out/baseq3/vm \
 && [ "$(ls /out/baseq3/vm/*.qvm 2>/dev/null | wc -l)" = "3" ]


# ===========================================================================
# pak-build -- package the compiled QVMs and the hf sound overrides.
#
# Light base with just zip; pulls the compiled output in via COPY --from.
#
# hf/buildpak3.sh is reused rather than reimplemented, so the definition of
# pak101's contents stays in one place. It runs against the in-image copy of hf/.
# ===========================================================================
FROM debian:11-slim AS pak-build

RUN apt-get update && apt-get install -y --no-install-recommends zip unzip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
RUN mkdir -p /paks

# pak100.pk3: the three QVMs, zipped with a vm/ prefix (rooted at baseq3/).
COPY --from=quake-build /out/baseq3/vm ./baseq3/vm
RUN cd baseq3 && zip -Dr /paks/pak100.pk3 vm
RUN unzip -l /paks/pak100.pk3 \
      | awk '/ vm\/(ui|cgame|qagame)\.qvm$/ { n++ } END { if (n != 3) exit 1 }'

# pak101.pk3: "Bow to my firewall!" replaces the Quad Damage announcement, plus
# the extra shot sound.
COPY hf/buildpak3.sh ./hf/buildpak3.sh
COPY hf/sounds       ./hf/sounds
RUN sh /work/hf/buildpak3.sh && cp /work/hf/build/pak101.pk3 /paks/pak101.pk3
RUN unzip -l /paks/pak101.pk3 \
      | awk '/ sound\/items\/(quaddamage|damage3)\.wav$/ { n++ } END { if (n != 2) exit 1 }'


# ===========================================================================
# paks -- extraction target for CI:
#
#   docker buildx build --target paks --output type=local,dest=artifacts .
# ===========================================================================
FROM scratch AS paks
COPY --from=pak-build /paks/pak100.pk3 /pak100.pk3
COPY --from=pak-build /paks/pak101.pk3 /pak101.pk3


# ===========================================================================
# shenanigans-build -- TypeScript for the in-page effects.
# ===========================================================================
FROM node:22-bookworm-slim AS shenanigans-build

WORKDIR /src

COPY package.json ./
COPY package-lock.json ./
# --ignore-scripts: the runtime dependency set includes very old packages with
# native build steps that are irrelevant to tsc and fail on modern node.
RUN --mount=type=cache,target=/root/.npm,sharing=locked \
    npm install --ignore-scripts --no-audit --no-fund

COPY tsconfig.json ./
COPY hf/shenanigans ./hf/shenanigans

# tsconfig.json pins outDir to html/hf/shenanigans/ relative to itself, so the
# layout here mirrors the repo rather than fighting the config.
RUN npx tsc

# The non-TypeScript assets that live alongside the sources (style.css, the
# background jpg, the per-effect subdirectories).
RUN cd hf/shenanigans \
 && tar -c --exclude '*.ts' . | tar -x -C /src/html/hf/shenanigans \
 && test -f /src/html/hf/shenanigans/Utils.js \
 && test ! -f /src/html/hf/shenanigans/Utils.test.js


# ===========================================================================
# content-fetch -- download the baseq3 asset set.
#
# ~260MB over the network and the least reproducible part of the build, so it is
# isolated in its own early stage: nothing in this repo can invalidate it.
# Consider mirroring the asset set internally and pointing ASSETS_SOURCE at it.
# ===========================================================================
FROM debian:11 AS content-fetch

RUN apt-get update && apt-get install -y --no-install-recommends \
      curl ca-certificates bash \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /srv/quake-assets

COPY dev/get_assets.sh .

# Optional mirror override, in the gh:owner/repo[@ref][:subdir] form documented
# in dev/get_assets.sh. Empty means the script's own default, so the default
# lives in exactly one place.
ARG ASSETS_SOURCE=
RUN bash get_assets.sh . ${ASSETS_SOURCE:+"$ASSETS_SOURCE"}


# ===========================================================================
# assets -- quakejs content server (bin/content.js) on port 9000.
#
# The content server and its package manifest come from the local checkout.
# quakejs-files was dropped from that manifest (see CONTAINERS.md); bin/content.js
# never required it.
# ===========================================================================
FROM debian:11-slim AS assets-deps

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates nodejs npm \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /srv/quake-assets
# dev/assets-package.json has no lockfile, so this is npm install, not npm ci.
# Committing a lockfile for it would make the assets image reproducible.
COPY dev/assets-package.json package.json
RUN --mount=type=cache,target=/root/.npm,sharing=locked \
    npm install --ignore-scripts --no-audit --no-fund


FROM debian:11-slim AS assets

# curl is here for the compose healthcheck, not for the app.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates nodejs curl \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --create-home --home-dir /home/quake quake

WORKDIR /srv/quake-assets

COPY --from=assets-deps /srv/quake-assets/node_modules ./node_modules
COPY bin/content.js ./bin/content.js

# content.js defaults its root to ../assets relative to bin/, and its port to
# 9000, so no config file is required.
COPY --from=content-fetch /srv/quake-assets/assets ./assets
COPY --from=pak-build /paks/pak100.pk3 /paks/pak101.pk3 ./assets/hf/

USER quake
EXPOSE 9000

ENTRYPOINT ["node", "bin/content.js"]


# ===========================================================================
# server -- the dedicated server.
#
# Stays on debian:11's node (12.x) deliberately: both the emscripten 1.13.2
# output and ws@0.4.29 predate modern node by a decade, and this is the
# combination that currently works.
# ===========================================================================
FROM debian:11-slim AS server

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates nodejs curl \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --create-home --home-dir /home/quake quake

WORKDIR /opt/ioq3

COPY --from=quake-build /out/ioq3ded.js        build/release-js-js/ioq3ded.js
COPY --from=quake-build /opt/ioq3/node_modules node_modules

# The server configs are the only tracked files under base/; games.log and
# q3config_server.cfg are runtime output (gitignored).
#
# --chown throughout: the engine writes those two files inside base/<fs_game>/
# (see below), so the whole tree must belong to the runtime user. Doing it on the
# COPY avoids a second full-size layer from a recursive chown.
COPY --chown=quake:quake base/baseq3/server.cfg base/baseq3/
COPY --chown=quake:quake base/cpma/server.cfg   base/cpma/
COPY --chown=quake:quake base/hf/server.cfg     base/hf/

# Game data, fetched at build time rather than downloaded at first run.
COPY --chown=quake:quake --from=content-fetch /srv/quake-assets/assets/ base/
# Freshly built paks take precedence over anything of the same name from the CDN.
COPY --chown=quake:quake --from=pak-build /paks/pak100.pk3 /paks/pak101.pk3 base/hf/

COPY dev/quake.sh bin/quake.sh

# Writable working directory. fs_homepath is resolved relative to the cwd, so the
# engine's writes land inside base/<fs_game>/ (owned by the runtime user via the
# --chown copies above) and FS_Startup may also want to create a directory in
# /opt/ioq3 itself. Without this, mkdirSync fails with EACCES and the fallback
# path reports a confusing ENOENT instead. See CONTAINERS.md.
#
# Nothing here is persisted; see compose.yml for the optional volume.
RUN chown quake:quake /opt/ioq3

USER quake
EXPOSE 27960
ENTRYPOINT ["sh", "bin/quake.sh"]


# ===========================================================================
# web -- static client.
#
# nginx on alpine is ~50MB and gzips the very large ioquake3.js on the way out.
#
# ioquake3.js comes from quake-build, not from the tracked copy in html/ (which
# .dockerignore excludes), so the image always carries a client built from the
# current submodule.
# ===========================================================================
FROM nginx:1.30-alpine AS web

RUN sed -i 's/^worker_processes.*/worker_processes 2;/' /etc/nginx/nginx.conf \
 && grep -q '^worker_processes 2;' /etc/nginx/nginx.conf

COPY dev/nginx.conf /etc/nginx/conf.d/default.conf

COPY html/ /usr/share/nginx/html/
COPY --from=quake-build       /out/ioquake3.js          /usr/share/nginx/html/ioquake3.js
COPY --from=shenanigans-build /src/html/hf/shenanigans  /usr/share/nginx/html/hf/shenanigans

EXPOSE 80
