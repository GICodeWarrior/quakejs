# Container build and deployment

This replaces `dev.sh`. Everything is built inside containers; no build step runs
on the host or writes to the working tree.

## Quick start

```shell
git submodule update --init      # ioq3 is the build's primary input
docker compose up -d
```

That is the whole thing -- no separate toolchain step. `Containerfile` contains a
`toolchain` stage (emscripten-fastcomp LLVM + emscripten 1.13.2), and
`TOOLCHAIN_IMAGE` defaults to the name of that stage, so it is built on demand.

The first build compiles LLVM and takes a long time. It is cached afterwards, but
because it lives in the same file as the rest of the build, an unlucky edit or a
`--no-cache` will rebuild it. Once things are stable, publish it and stop
rebuilding it locally:

```shell
docker build --target toolchain -t ghcr.io/<owner>/quakejs/toolchain:main .
docker push ghcr.io/<owner>/quakejs/toolchain:main
```

Then point at it, e.g. in a `.env` file:

```
TOOLCHAIN_IMAGE=ghcr.io/<owner>/quakejs/toolchain:main
```

With that set, the toolchain stages fall outside the build graph and are never
executed. The Container Images workflow publishes this image on every push to
`main`.

- web: <http://localhost:8080>
- content server: <http://localhost:9000/assets/manifest.json>
- dedicated server: `localhost:27960` (WebSockets, so TCP)

## Development

```shell
docker compose -f compose.yml -f compose.dev.yml watch
```

Editing `ioq3/code`, `hf/shenanigans`, `hf/sounds`, or `html` rebuilds only the
affected images. Static files under `html/` are synced into the running web
container without a rebuild.

Builds are incremental: `Containerfile` mounts build caches for the ioq3 object
directory and the emscripten cache, so a one-file change to `ioq3/code`
recompiles that translation unit and relinks rather than rebuilding everything.

This relies on `COPY` preserving mtimes from the working tree, which is what lets
`make` compare sources against cached objects. A fresh clone flattens mtimes, so
CI does full rebuilds; there, speed comes from the pinned toolchain image and the
GitHub Actions layer cache instead.

Tests still run through npm directly:

```shell
npm install --no-package-lock
npm exec mocha
```

`--no-package-lock` is needed until the lockfile is regenerated; see the note on
`quakejs-files` under Open items.

## Images

| Image | Contents | Port |
|---|---|---|
| `web` | nginx, `index.html`, `ioquake3.js`, compiled shenanigans | 80 |
| `server` | `ioq3ded.js`, `ws@0.4.29`, `base/` game data, `server.cfg`s | 27960 |
| `assets` | `bin/content.js`, baseq3 asset set, `pak100`/`pak101` | 9000 |

They are kept separate because their contents genuinely differ, not just their
entrypoints. The only overlap is the built pak files, which come from a shared
build stage.

Build targets in `Containerfile`: `web`, `server`, `assets`, plus `toolchain`
(above) and `paks`, a scratch image holding just the two pk3 files for CI
extraction:

```shell
docker buildx build --target paks --output type=local,dest=artifacts .
```

## What changed

- **No bind mounts.** Each image carries its artifacts. `docker compose up` works
  from `compose.yml` alone, with no checkout of this repository.
- **No host build steps.** The former `dev.sh` extraction (`docker run ... | tar`
  back onto the host), the host `hf/buildpak3.sh` run, the host `npm exec tsc`,
  and the host `touch ioq3/code/tools/lcc/lburg/gram.c` are all build stages now.
  `hf/buildpak3.sh` is still the definition of pak101's contents, but it runs
  against the in-image copy of `hf/`.
- **Game data is fetched at build time.** `dev/get_assets.sh` runs in a build
  stage and `dev/derive-base.sh` converts the crc32-prefixed download into the
  plain-named `base/` tree the Quake filesystem needs, so the dedicated server no
  longer downloads the asset set on first run.
- **`dev/patch-quake.sh` is no longer run.** The pinned submodule already
  contains its edits, in a form that differs from what the script generates, so
  re-running it would corrupt the tree. `Containerfile` asserts the tree is
  patched instead, and fails the build if the submodule is bumped to an
  unpatched commit.
- **The assets image is built locally** (reviving `dev/Dockerfile.assets`)
  instead of pulling a prebuilt image and bind-mounting `./base/hf` over it.

## Open items

- **Client-facing CDN address.** `dev/quake.sh` defaults `fs_cdn` to
  `assets:9000`, which resolves via compose DNS for the server but is not
  resolvable by a browser. A public CDN hostname likely needs to be threaded into
  the web content for a real deployment. `bin/wssproxy.js` also exists but is not
  wired into compose; if a proxy fronts the dedicated server in production, that
  belongs here too.
- **`html/ioquake3.js` is still tracked** but is no longer a build input
  (`.dockerignore` excludes it; the web image takes the client from the build).
  It can be removed from git once you are satisfied the built client matches.
- **`quakejs-files` has been unpublished from npm.** The `0.0.3` tarball returns
  404, so it was removed from both `package.json` and `dev/assets-package.json` to
  make installs work again. Two consequences:
  - `package-lock.json` still pins the dead tarball, so `npm ci` cannot succeed.
    The container build uses `npm install --no-package-lock` instead. Regenerate
    the lockfile (`rm package-lock.json && npm install`) as its own commit to
    restore `npm ci`, here and on the host.
  - `lib/asset-graph.js` requires it, so `bin/repak.js` is unusable until the
    package is vendored or replaced. This is pre-existing, not caused by the
    container work -- and it is very likely why `dev/Dockerfile.assets` was
    commented out in `dev.sh` and `ghcr.yaml` in favour of pulling a prebuilt
    image built before the package disappeared. Nothing in the three runtime
    images needs it.
- **`base/` layout from the CDN.** Verify that `dev/derive-base.sh` produces a
  tree the dedicated server accepts. If the content server's manifest yields a
  repacked, map-specific set rather than `pak0`–`pak8`, fall back to letting the
  server self-download into a volume mounted at `/var/lib/quake` (the commented
  `quake-home` volume in `compose.yml`).
- **Debian 11.** Required for python2, which emscripten 1.13.2 needs. Bullseye
  LTS ends 2026-08; the toolchain section of `Containerfile` has a commented
  mirror rewrite for when the packages move to `archive.debian.org`. Pushing the
  built toolchain image is the real mitigation.
