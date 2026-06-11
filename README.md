# container-images

Self-hosted container images for the homehosted cluster.

This repo builds hardened Servarr images for Prowlarr, Radarr, and Sonarr on Red Hat Hummingbird distroless bases. The goal is to replace upstream LinuxServer.io images with images built from official Servarr release tarballs, pinned checksums, signed GHCR publishes, SBOMs, and provenance attestations.

Images will be published to:

- `ghcr.io/major/prowlarr`
- `ghcr.io/major/radarr`
- `ghcr.io/major/sonarr`

The `homehosted` GitOps repo consumes these images through the existing HelmReleases for each app.

## Layout

```text
container-images/
├── .github/workflows/
├── images/
│   ├── prowlarr/
│   ├── radarr/
│   └── sonarr/
├── renovate.json
└── README.md
```
