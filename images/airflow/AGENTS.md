# AGENTS.md (airflow image)

This file documents conventions specific to `images/airflow/`. The top-level
`/AGENTS.md` covers repo-wide conventions (two-stage builds, Renovate
behavior, CI flow, etc.) and is the source of truth for anything not
covered here. Update both files together when the airflow image changes.

## What this image is

A Hummingbird-distroless rebuild of **Apache Airflow 3.x** on
`registry.access.redhat.com/hi/python:3.12`, with the full upstream
`AIRFLOW_EXTRAS` list (~35 extras) — equivalent to
`apache/airflow:latest`. Pinned version + SHA512, signed GHCR publish,
SBOM, provenance attestation, same as every other image in this repo.

## Layout

- `Containerfile` — multi-stage build (Hummingbird builder →
  Hummingbird distroless). The `RUN` block is intentionally tiny; the
  heavy lifting is in `build.sh`.
- `build.sh` — extracted build script (per maintainer preference — a
  20+ line `RUN` in the Containerfile is hard to read). Runs inside
  the builder, creates the venv, downloads + verifies the wheel,
  applies the constraints file, pip-installs, strips build deps.

## Bases

- Builder: `registry.access.redhat.com/hi/python:3.12-builder` (pinned
  by digest, tags are patch-versioned, e.g. `3.12.13-builder`).
- Runtime: `registry.access.redhat.com/hi/python:3.12` (distroless,
  no shell, UID `65532`; we override to `50000:0` in the final stage).
- Both are from the same Hummingbird `python` stream so the venv's
  `bin/python3.12` symlink resolves to `/usr/sbin/python3.12` in both
  images — no need to bundle a Python binary.

## Pin format

- `ARG AIRFLOW_VERSION` (PEP 440) — bumped by Renovate from PyPI.
- `ARG AIRFLOW_SHA512` — wheel checksum from
  `https://downloads.apache.org/airflow/<ver>/apache_airflow-<ver>-py3-none-any.whl.sha512`.
  Upstream ships `.sha512` only, not `.sha256`. Renovate cannot
  auto-update this — every version bump requires a manual hash update
  in the same PR, otherwise CI fails at `sha512sum -c`.
- `ARG AIRFLOW_EXTRAS` — comma-separated list. Defaults to the upstream
  `main` full-extras list (the 35-extras `apache/airflow:latest`
  surface). Narrow with `--build-arg AIRFLOW_EXTRAS=postgres,redis` for
  a slimmer image. Not auto-updated by Renovate; the list drifts with
  upstream and must be cross-checked at each version bump.
- The `AIRFLOW_VERSION` ARG is declared twice (once per stage). CI
  overrides the second-stage value via `docker/metadata-action` for
  published images, but a local `podman build` will produce a stale
  `org.opencontainers.image.version` label until the second-stage
  ARG is bumped too.

## Constraints file

Downloaded at build time from
`https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-3.12.txt`.
Git-tag-versioned, no extra checksum. Applied with
`pip install --constraint`. This is what gives reproducible transitive
deps across Airflow's many extras.

## Venv + entrypoint

- Venv created at `/opt/airflow` in the builder.
- `COPY --from=builder --chown=50000:0 /opt/airflow /opt/airflow` —
  wholesale to the distroless stage.
- `ENTRYPOINT ["/opt/airflow/bin/airflow"]`. Users pass subcommands
  (`webserver`, `scheduler`, `dag-processor`, `worker`, `triggerer`,
  `migrate`, `version`, ...) via `CMD` or container args.
- `ENV AIRFLOW_HOME=/opt/airflow` + `VOLUME ["/opt/airflow"]`. Logs,
  dags, plugins, and the SQLite metadata DB all live under the
  volume. Postgres deployments override
  `AIRFLOW__DATABASE__SQL_ALCHEMY_CONN`.

## build.sh conventions (the bits that bite)

- The script runs as **root** in the builder stage (the Hummingbird
  builder's default UID is `65532`, which can't write to `/opt/`).
  The runtime stage is unprivileged.
- `dnf install` of dev headers (`gcc`, `python3.12-devel`,
  `mariadb-connector-c-devel`, `openldap-devel`, `cyrus-sasl-devel`,
  `libffi-devel`, `bzip2-devel`, `xz-devel`, `zlib-ng-compat-devel`,
  `sqlite-devel`, plus `unixODBC-devel` + `postgresql-devel` +
  `libxml2-devel` + `libxslt-devel` for completeness) plus `git`.
  `--skip-unavailable` because the Hummingbird repos don't ship every
  -devel RPM.
- **Do not** add `dnf -y autoremove` after the explicit
  `dnf -y remove` of the dev headers. Autoremove would strip runtime
  libs (`mariadb-connector-c`, `openldap`, `cyrus-sasl-lib`) that the
  runtime stage needs to COPY. After the remove, the script
  re-installs the runtime packages explicitly to guarantee they're
  present in the builder.
- `git` is intentionally **not** in the dnf-remove list — the runtime
  stage COPYs `/usr/bin/git` and `/usr/libexec/git-core/`.
- `find ... -name '__pycache__' -prune -exec rm -rf {} +` and
  `find ... -name '*.pyc' -delete` at the end strip ~50-100 MB of
  useless bytecode caches (the runtime sets
  `PYTHONDONTWRITEBYTECODE=1`).

## Runtime .so copies

The Hummingbird distroless runtime doesn't carry these and they
aren't bundled into the airflow wheel's manylinux packages. Copied
from the builder to `/usr/lib64/` in the runtime stage:

| Glob | Why |
|------|-----|
| `libldap.so.2*`, `liblber.so.2*`, `libsasl2.so.3*` | `python-ldap` (`ldap` extra) — dynamically links against the system OpenLDAP + SASL |
| `libevent-2.1.so.7*` | `python-ldap` async I/O |
| `libmariadb.so.3*` | `mysqlclient` (`mysql` extra) — has no PyPI manylinux wheel, builds from C source against `mariadb-connector-c-devel` and dynamically links to the system libmariadb |

`psycopg2-binary`, `lxml`, and `pyarrow` ship manylinux wheels that
bundle their own deps into site-packages, so no system copy is
needed for those.

## Known limitations (documented, not blocking)

- **`odbc` extra is non-functional**: the Hummingbird minimal
  `public-hummingbird-x86_64-rpms` repo does not ship `unixODBC`
  (only the unrelated `erlang27-odbc`). The `odbc` extra in the full
  upstream list pulls in `pyodbc`, which has no manylinux wheel
  bundling `libodbc.so.2`. `import pyodbc` fails at runtime. This is
  a property of the Hummingbird base image, not a build bug. Fix
  options for a follow-up: build `unixODBC` from source in the
  builder; add a non-Hummingbird RPM repo (breaks minimal-design
  invariant); document and let users install on the host.
- **No init (tini/dumb-init)**: the airflow process is PID 1.
  `airflow scheduler` and `airflow celery worker` spawn child
  processes; without a proper init, zombies can accumulate and SIGTERM
  propagation to children is imperfect. Users should run with
  `--init` (podman/docker) or use a Kubernetes pod that provides a
  proper init.
- **`AIRFLOW_EXTRAS` is not auto-updated by Renovate**: when upstream
  adds or removes an extra, a human must update the Containerfile.
  This is the right trade-off for a full-image build; Renovate can't
  track an arbitrary comma-list from PyPI metadata.
- **`git` HTTPS operations need a CA bundle**: the Hummingbird
  distroless base ships a default CA bundle at `/etc/pki/tls/certs/`,
  not a problem in practice but worth noting for users who mount
  custom CA bundles.
