# AGENTS.md

## ⚠️ Keep this file current (high priority)

Whenever something changes in this repo (new image, new CI step, renovate behavior, base image swap, build flow), update this file in the same change. A stale AGENTS.md is worse than none.

## What this repo is

Hardened, pinned rebuilds of self-hosted apps on Red Hat Hummingbird distroless bases. Each image replaces an upstream image with pinned checksums, signed GHCR publishes, SBOMs, and provenance attestations. Published to `ghcr.io/major/<app>`.

Current images: `prowlarr`, `radarr`, `sonarr` (all Servarr .NET apps).

## Layout

- `images/<app>/Containerfile` - one multi-stage Containerfile per app. This is the only build artifact; there is no Makefile or build script.
- `.github/workflows/build.yaml` - the entire build/sign/attest pipeline, driven by a matrix.
- `renovate.json` - dependency automation, including a custom Servarr datasource.

## Containerfile conventions (non-obvious)

- **Two-stage build**: UBI9 builder downloads + checksum-verifies the release tarball; final stage is `registry.access.redhat.com/hi/dotnet-runtime:8.0` (Hummingbird distroless, no shell/package manager).
- **Version + checksum are pinned in `ARG`s** and the version `ARG` is **declared twice** (once per stage). When bumping a version manually, update both. Renovate normally handles this.
- The `# renovate:` comment immediately above the `ARG <APP>_VERSION` / `ARG <APP>_SHA256` lines is load-bearing. Its exact format and line ordering are matched by the regex in `renovate.json` -> `customManagers`. Do not reformat those three lines.
- `SHA256` here is the Servarr release-tarball checksum (verified with `sha256sum -c`), not a digest of the base image.
- Final stage runs as non-root `USER 1026:100`; files are `COPY --chown=1026:100`. `libsqlite3.so.0*` is copied from the builder because the distroless runtime lacks it.
- `XDG_CONFIG_HOME=/config`, `/config` is a volume, app data lives there (`-data=/config`).

## Adding a new image

1. Create `images/<app>/Containerfile` following an existing one.
2. Add a matrix entry in `.github/workflows/build.yaml` with `app`, `arg_prefix` (uppercase, matches the `ARG` prefix), and `update_url` (the Servarr update API endpoint).
3. If it is a Servarr app, add it to the `managerFilePatterns` regex alternation in `renovate.json` -> `customManagers`.

## CI / build flow

- No local build tooling. Builds run in GitHub Actions; for local testing use `podman build images/<app>`.
- CI steps: read pinned version/checksum from the Containerfile -> verify checksum against the Servarr update API (warn-only) -> buildx build -> push (non-PR only) -> cosign sign -> attest provenance.
- PRs build but do **not** push, sign, or attest. Publishing happens only on `main`, schedule, or manual dispatch.
- All `uses:` actions are pinned to commit SHAs. Keep them pinned (renovate updates them).

## Renovate behavior

- Hummingbird base image digest bumps: pinned + auto-merged immediately, constrained to the `8.0` tag.
- Servarr minor/patch: auto-merged after a 3-day stability window.
- Servarr major: labeled `major-update`, requires manual review.
