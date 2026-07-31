# Container build and deployment

## Quick start

```shell
git submodule update --init      # ioq3 is the build's primary input
docker compose up -d
```

The first build compiles LLVM and takes a long time. It's cached afterwards.

Containers are named `quakening-<service>-1`; use `docker compose logs -f quake`
and `docker compose exec quake sh` rather than fixed container names.

- web: <http://localhost:8080>
- asset manifest: <http://localhost:8080/assets/manifest.json>
- dedicated server: `localhost:27960` (WebSockets)

## Development

```shell
docker compose up --build --watch
```

Editing `ioq3`, `hf/shenanigans`, `hf/sounds`, or `html` rebuilds only the
affected images. Static files under `html/` are synced into the running web
container without a rebuild.

Builds are incremental: `Containerfile` mounts build caches for the ioq3 object
directory and the emscripten cache, so a one-file change under `ioq3/code`
recompiles that translation unit and relinks rather than rebuilding everything.

## Assets

The `content-fetch` stage clones game data from a GitHub mirror on
every cache miss. To point it elsewhere, set `ASSETS_REPO`, and optionally
`ASSETS_REF`, in `.env` or the environment:

```
ASSETS_REPO=https://github.com/my-org/quake-assets.git
ASSETS_REF=main
```

Assets are cataloged at build time. `dev/catalog-assets.sh` runs in the
`content-catalog` build stage and writes the asset set into the layout the engine
asks for:

```
assets/manifest.json          [{name, compressed, checksum}, ...]
assets/<dir>/<crc>-<name>     every asset, stored under its own CRC32
```

## Images

| Image | Contents | Port |
|---|---|---|
| `web` | nginx, `index.html`, `ioquake3.js`, compiled shenanigans, cataloged assets | 80 |
| `server` | `ioq3ded.js`, `ws@0.4.29`, `base/` game data, `server.cfg`s | 27960 |

