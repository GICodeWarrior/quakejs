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

Containers are named `quakening-<service>-1`; use `docker compose logs -f quake`
and `docker compose exec quake sh` rather than fixed container names. If you still
have containers from the old stack, remove them once:
`docker rm -f quake quake-web quake-assets`.

- web: <http://localhost:8080>
- content server: <http://localhost:9000/assets/manifest.json>
- dedicated server: `localhost:27960` (WebSockets, so TCP)

## Development

```shell
docker compose -f compose.yml -f compose.dev.yml up --build --watch
```

Editing `ioq3`, `hf/shenanigans`, `hf/sounds`, or `html` rebuilds only the
affected images. Static files under `html/` are synced into the running web
container without a rebuild.

Builds are incremental: `Containerfile` mounts build caches for the ioq3 object
directory and the emscripten cache, so a one-file change under `ioq3/code`
recompiles that translation unit and relinks rather than rebuilding everything.

This relies on `COPY` preserving mtimes from the working tree, which is what lets
`make` compare sources against cached objects. A fresh clone flattens mtimes, so
CI does full rebuilds; there, speed comes from the pinned toolchain image and the
GitHub Actions layer cache instead.

Tests still run through npm directly:

```shell
npm install
npm exec mocha
```

## Asset mirror

The `content-fetch` stage downloads ~260MB of game data from a GitHub mirror on
every cache miss. To point it elsewhere, set `ASSETS_SOURCE` (in `.env` or the
environment) to a `gh:owner/repo[@ref][:subdir]` spec:

```
ASSETS_SOURCE=gh:my-org/quake-assets@main:assets
```

`compose.yml` passes it to both the `assets` and `quake` builds; keep them in
step, or the two builds each fetch their own copy. Leaving it unset uses the
default in `dev/get_assets.sh`, which is the single source of truth for it.

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

## Open items

- **Client and server reach the CDN by different names.** `dev/quake.sh` defaults
  `fs_cdn` to `assets:9000`, which resolves via compose DNS but not from a
  browser. The browser client does not use that value: `html/index.html` builds
  its own `fs_cdn` and `+connect` from `document.location.hostname` plus the
  hardcoded ports 9000 and 27960. So a single-host deployment works as-is, but
  the published ports in `compose.yml` are effectively fixed, and splitting the
  services across hosts means editing `html/index.html`. `bin/wssproxy.js` also
  exists but is not wired into compose; if a proxy fronts the dedicated server in
  production, that belongs here too.
- **The whole `ioq3` submodule is copied into the build**, not just `Makefile`
  and `code/`. `code/ui/ui_shared.h` includes `../../ui/menudef.h`, so the
  top-level `ui/` directory is required too, and the Makefile reaches for other
  non-code paths besides. Copying the tree wholesale is cheaper than predicting
  which ones; `.dockerignore` trims the parts that must not come along.
- **`fs_homepath` must be relative.** `code/sys/sys_node.js` does
  `PATH.join('.', fs_homepath)` and uses the result as both the NODEFS host root
  and the emscripten mount point, so an absolute value loses its leading slash and
  FS_Startup fails. The entrypoint therefore leaves it unset, which means the
  engine writes `games.log` and `q3config_server.cfg` inside `base/<fs_game>/`
  rather than in a separate state directory.
- **Debian 11.** Required for python2, which emscripten 1.13.2 needs. Bullseye
  LTS ends 2026-08; the toolchain section of `Containerfile` has a commented
  mirror rewrite for when the packages move to `archive.debian.org`. Pushing the
  built toolchain image is the real mitigation.
