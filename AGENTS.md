# AGENTS.md

## ⚠️ Keep this file current (high priority)

Whenever something changes in this repo (new image, new CI step, renovate behavior, base image swap, build flow), update this file in the same change. A stale AGENTS.md is worse than none.

## What this repo is

Hardened, pinned rebuilds of self-hosted apps on Red Hat Hummingbird distroless bases. Each image replaces an upstream image with pinned checksums, signed GHCR publishes, SBOMs, and provenance attestations. Published to `ghcr.io/major/<app>`.

Current images:

- `prowlarr`, `radarr`, `sonarr` — Servarr .NET apps on `hi/dotnet-runtime:8.0`.

## Layout

- `images/<app>/Containerfile` - one multi-stage Containerfile per app.
- `.github/workflows/build.yaml` - the entire build/sign/attest pipeline, driven by a matrix.
- `renovate.json` - dependency automation, including a custom Servarr datasource.

## Containerfile conventions (non-obvious)

Common to all images:

- **Two-stage build**: Hummingbird builder (or UBI9 for Servarr) downloads and checksum-verifies the upstream artifact; final stage is the matching Hummingbird distroless base.
- **Version + checksum are pinned in `ARG`s** and the version `ARG` is **declared twice** (once per stage). When bumping a version manually, update both. Renovate updates the first-stage ARG; the second-stage ARG (used only for the image `LABEL`) is overridden by CI via `docker/metadata-action` for published images, so a local `podman build` will produce a stale `org.opencontainers.image.version` label until the second-stage ARG is bumped too.
- The `# renovate:` comment immediately above the version `ARG` is load-bearing. Its exact format and line ordering are matched by the regex in `renovate.json` -> `customManagers`. Do not reformat those lines.
- Base image references are pinned by `@sha256:<digest>` (no floating tags). Renovate updates the digest via the `docker` datasource.
- Final stage runs as non-root; files are `COPY --chown=<uid>:<gid>`.

Servarr-specific (`.NET` runtime, image dirs `images/{prowlarr,radarr,sonarr}/`):

- Builder is `registry.access.redhat.com/ubi9/ubi`; final is `registry.access.redhat.com/hi/dotnet-runtime:8.0`.
- Pin format: `ARG <APP>_VERSION` + `ARG <APP>_SHA256=<sha256>` (release tarball, verified with `sha256sum -c`).
- Final user: `1026:100`. `libsqlite3.so.0*` is copied from the builder because the distroless runtime lacks it.
- `XDG_CONFIG_HOME=/config`, `/config` is a volume, app data lives there (`-data=/config`).

## Adding a new image

1. Create `images/<app>/Containerfile` following an existing Servarr image.
2. Add a matrix entry in `.github/workflows/build.yaml` with `app`, `arg_prefix` (uppercase, matches the `ARG` prefix), and `update_url` (the version-endpoint URL the CI step will hit to verify the pinned version is still current).
3. Add (or extend) a `customManagers` block in `renovate.json` whose `managerFilePatterns` targets the new image's `Containerfile` and whose datasource matches the pin family (PyPI for python packages, `custom.<family>` for tarball+checksum flows).

## CI / build flow

- No local build tooling. Builds run in GitHub Actions; for local testing use `podman build images/<app>`.
- CI steps: read pinned version/checksum from the Containerfile -> for Servarr images, verify the pinned checksum still matches the update API (warn-only; other images skip this step via the `sha256 != ''` guard) -> buildx build -> push (non-PR only) -> cosign sign -> attest provenance.
- PRs build but do **not** push, sign, or attest. Publishing happens only on `main`, schedule, or manual dispatch.
- All `uses:` actions are pinned to commit SHAs. Keep them pinned (renovate updates them).

## Renovate behavior

- Hummingbird base image digest bumps: pinned + auto-merged immediately, constrained to the `8.0` dotnet tag.
- Servarr minor/patch: auto-merged after a 3-day stability window.
- Servarr major: labeled `major-update`, requires manual review.
