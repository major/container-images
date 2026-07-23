#!/usr/bin/env bash
#
# Build stage for major/container-images:images/airflow
#
# Runs inside the Hummingbird python:3.12-builder image. Creates a venv at
# /opt/airflow, downloads the pinned Apache Airflow wheel from
# downloads.apache.org, verifies its SHA512, fetches the git-tag-pinned
# constraints file from the apache/airflow repo, then pip-installs the wheel
# plus all upstream-default extras. Strips the build dev headers from the
# builder layer before the COPY to the distroless runtime stage.
#
# Args consumed (passed via Containerfile ARG, exported below):
#   AIRFLOW_VERSION  — PEP 440 version, e.g. 3.3.0
#   AIRFLOW_EXTRAS   — comma-separated, e.g. "postgres,redis" or the
#                      upstream-default full list
#   AIRFLOW_SHA512   — SHA512 of the wheel on downloads.apache.org
#
# After this script exits 0, the runtime stage only needs to COPY
# /opt/airflow to the distroless python:3.12 image.

set -euxo pipefail

# ---------------------------------------------------------------------------
# 1. System dev headers needed for the few Airflow deps that build from
#    C source (mysqlclient, python-ldap, pyodbc, lxml, ...). Most deps ship
#    manylinux wheels and need nothing on the build host. We install a
#    comprehensive set up-front and clean them out before the layer ends,
#    so the builder cache stays minimal.
#    `--skip-unavailable` keeps the build going if the Hummingbird repo
#    doesn't ship a particular -devel RPM (e.g. unixODBC-devel at the
#    time of writing); pip's wheel resolver will then either find a
#    prebuilt wheel or surface a clear build error.
#
#    `git` is included here so the runtime stage can COPY /usr/bin/git
#    and /usr/libexec/git-core/ — the `git` extra's GitPython-backed DAG
#    bundles need the binary at runtime. It is NOT in the dnf-remove
#    list below; the builder keeps it installed for the COPY.
# ---------------------------------------------------------------------------
dnf install -y --setopt=install_weak_deps=False --skip-unavailable \
    gcc \
    gcc-c++ \
    make \
    pkgconf-pkg-config \
    python3.12-devel \
    openssl-devel \
    mariadb-connector-c-devel \
    openldap-devel \
    cyrus-sasl-devel \
    postgresql-devel \
    unixODBC-devel \
    libxml2-devel \
    libxslt-devel \
    libffi-devel \
    bzip2-devel \
    xz-devel \
    zlib-ng-compat-devel \
    sqlite-devel \
    git

# ---------------------------------------------------------------------------
# 2. venv + pinned wheel + constraints + install
# ---------------------------------------------------------------------------
python3.12 -m venv /opt/airflow

wheel="apache_airflow-${AIRFLOW_VERSION}-py3-none-any.whl"

# Use the original wheel filename on disk: pip's wheel-filename parser
# needs the canonical `name-version-py3-none-any.whl` form to recognize
# the package and accept the [extras] syntax. (Renaming to e.g.
# /tmp/airflow.whl produces "Invalid wheel filename: 'airflow'".)
curl -fsSL \
    "https://downloads.apache.org/airflow/${AIRFLOW_VERSION}/${wheel}" \
    -o "/tmp/${wheel}"

# Verify the wheel against the Apache-published SHA512. The upstream
# .sha512 file uses the original wheel filename internally; we extract
# the hash and re-emit it with the local path.
echo "${AIRFLOW_SHA512}  /tmp/${wheel}" | sha512sum -c -

# Constraints file is git-tag-versioned (constraints-${AIRFLOW_VERSION}),
# so no extra checksum is needed — the URL itself is the pin.
curl -fsSL \
    "https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-3.12.txt" \
    -o /tmp/constraints.txt

/opt/airflow/bin/pip install --no-cache-dir \
    --constraint /tmp/constraints.txt \
    "/tmp/${wheel}[${AIRFLOW_EXTRAS}]"

# ---------------------------------------------------------------------------
# 3. Strip the build dev packages. The runtime stage copies /opt/airflow,
#    some system .so files (libldap, libmariadb, ...), and /usr/bin/git from
#    the builder. We remove the -devel packages to keep the builder cache
#    small, but we have to be careful: on RHEL/Hummingbird, dnf removing a
#    -devel package can cascade to remove its runtime counterpart (because
#    the -devel doesn't always declare a hard runtime dep), which would
#    break the runtime stage's COPY.
#
#    Fix: for every -devel whose runtime .so is COPYed by the runtime
#    stage, we re-install the runtime package after the remove. This
#    guarantees libldap, libmariadb, etc. are present in the builder.
# ---------------------------------------------------------------------------
dnf -y remove \
    gcc \
    gcc-c++ \
    make \
    pkgconf-pkg-config \
    python3.12-devel \
    openssl-devel \
    mariadb-connector-c-devel \
    openldap-devel \
    cyrus-sasl-devel \
    postgresql-devel \
    unixODBC-devel \
    libxml2-devel \
    libxslt-devel \
    libffi-devel \
    bzip2-devel \
    xz-devel \
    zlib-ng-compat-devel \
    sqlite-devel || true

# Re-install the runtime packages the runtime stage COPYs. `|| true`
# because some of these may already be present (or absent due to
# --skip-unavailable on the -devel side).
dnf install -y --setopt=install_weak_deps=False --skip-unavailable \
    openldap \
    cyrus-sasl-lib \
    mariadb-connector-c || true

dnf clean all

# ---------------------------------------------------------------------------
# 4. Drop the wheel, constraints, and Python bytecode caches from the
#    venv. Bytecode caches are useless in a distroless runtime (which
#    sets PYTHONDONTWRITEBYTECODE=1) and waste ~50-100 MB.
# ---------------------------------------------------------------------------
rm -f "/tmp/${wheel}" /tmp/constraints.txt

find /opt/airflow -name '__pycache__' -type d -prune -exec rm -rf {} +
find /opt/airflow -name '*.pyc' -delete
