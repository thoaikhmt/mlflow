# Custom MLflow tracking server image with the `mlflow-oidc-auth` plugin, so the
# server can authenticate against Azure Entra ID (OIDC) instead of only MLflow's
# built-in basic auth.
#
# Base is the official `-full` image: it already bundles the Postgres/S3 drivers
# (`psycopg2`, `boto3`) and pins MLflow to the same version we want. We only add
# the plugin and pin MLflow so pip cannot drift the MLflow version the plugin
# was validated against (`mlflow-oidc-auth` allows `mlflow>=3.16,<4`).
#
# The `[cache]` extra is installed so the plugin can use the Redis cache backend
# (`CACHE_BACKEND=redis`) to share session/permission caches across replicas. The
# `[saml]`/`[full]` extras are deliberately NOT installed: they build `xmlsec`
# from source and the `-full` image lacks the dev headers, and Entra ID SSO is
# plain OIDC.
#
# The plugin source is VENDORED under ./mlflow-oidc-auth so we own and can patch
# it (including the --static-prefix handling in `_prefix.py`). Installing
# straight from an upstream source tarball silently shipped NO admin UI:
# `mlflow_oidc_auth/ui` is the React build output, is git-ignored, and is not in
# the archive, so `pip install` produced a wheel without it and every
# `/oidc/ui/*` request died with `RuntimeError: UI directory not found`. The
# `ui` stage below builds the frontend first; the runtime stage installs the
# plugin from source with the built assets in place. We also fixed
# `hack/menu.html`, whose relative `oidc/ui/user` / `logout` links resolved
# under /mlflow and 404'd.

# ── Stage 1: build the React admin UI into mlflow_oidc_auth/ui ──────────────
# Vite is configured with `outDir: ../mlflow_oidc_auth/ui`, so building from
# web-react/ writes the bundle into the sibling package directory.
FROM node:24-bookworm-slim AS ui

WORKDIR /plugin

# The node:24 image already ships yarn 1.22.22, which honours the v1 yarn.lock.
RUN yarn --version

COPY mlflow-oidc-auth/web-react/package.json mlflow-oidc-auth/web-react/yarn.lock ./web-react/
RUN yarn --cwd web-react install --frozen-lockfile

COPY mlflow-oidc-auth/web-react/ ./web-react/
RUN yarn --cwd web-react build \
    && test -f mlflow_oidc_auth/ui/index.html

# ── Stage 2: runtime image (official -full + vendored plugin + built UI) ────
FROM ghcr.io/mlflow/mlflow:v3.17.1-full

ARG MLFLOW_VERSION=3.17.1
ARG MLFLOW_OIDC_AUTH_VERSION=7.0.0

USER root

# Stamp the plugin's dynamic version (setuptools reads this at build time)
# instead of the source default `7.0.0.dev0`.
ENV MLFLOW_OIDC_AUTH_VERSION=${MLFLOW_OIDC_AUTH_VERSION}

# Copy the vendored plugin source, then overwrite/ensure the built UI is present.
COPY mlflow-oidc-auth/ /opt/mlflow-oidc-auth/
COPY --from=ui /plugin/mlflow_oidc_auth/ui /opt/mlflow-oidc-auth/mlflow_oidc_auth/ui

RUN pip install --no-cache-dir \
        "mlflow==${MLFLOW_VERSION}" \
        "/opt/mlflow-oidc-auth[cache]"

# ── Patch MLflow's UI: auto-refresh the GenAI "Evaluations" run list ────────
# The experiment Evaluations tab lists runs via POST /ajax-api/2.0/mlflow/runs/search
# (useExperimentEvaluationRunsData: cacheTime 0, refetchOnWindowFocus false) and only
# refetches when the UI's own "Evaluate traces" button invalidates that query. Eval runs
# created outside the UI — a notebook/CLI mlflow.genai.evaluate loop — fire no such
# invalidation, and the experiment page keeps the tab mounted, so the list stayed frozen
# on its first snapshot until a full page reload. Give exactly that one query a refetch
# interval so new eval runs appear on their own. The query is located by its
# `queryKey:["SEARCH_RUNS",` prefix (the other match, the "Evaluate traces" button's
# invalidateQueries call, carries no query options), so only it is rewritten; the build
# fails loudly if a future MLflow bump rewords the query rather than silently shipping an
# unpatched UI.
RUN python - <<'PY'
import glob
import os
import sys

import mlflow

static_js = os.path.join(os.path.dirname(mlflow.__file__), "server", "js", "build", "static", "js")
anchor = 'queryKey:["SEARCH_RUNS",'
before = "cacheTime:0,refetchOnWindowFocus:!1,retry:!1,enabled:"
after = "cacheTime:0,refetchOnWindowFocus:!1,retry:!1,refetchInterval:5e3,enabled:"

patched = []
for path in glob.glob(os.path.join(static_js, "**", "*.js"), recursive=True):
    with open(path, "r", encoding="utf-8") as f:
        source = f.read()
    if anchor not in source:
        continue
    index = source.find(before, source.find(anchor))
    if index == -1:
        continue
    patched.append((path, source[:index] + source[index:].replace(before, after, 1)))

if len(patched) != 1:
    sys.exit(f"eval-runs auto-refresh patch: expected exactly 1 query, found {len(patched)}")

path, patched_source = patched[0]
with open(path, "w", encoding="utf-8") as f:
    f.write(patched_source)
print("patched eval-runs auto-refresh in", os.path.basename(path))
PY

# Fail the build if the plugin (or a driver it needs) is not importable, or if
# the admin UI did not make it into the installed package. The Entra ID group
# plugin resolves group object IDs to names via Microsoft Graph.
RUN python - <<'PY'
import importlib.metadata as md
import os

import mlflow
import mlflow_oidc_auth  # noqa: F401  (registers the `oidc-auth` MLflow app)
import redis  # noqa: F401  (Redis cache backend, installed via the [cache] extra)
from mlflow_oidc_auth.plugins import group_detection_microsoft_entra_id  # noqa: F401

ui_dir = os.path.join(os.path.dirname(mlflow_oidc_auth.__file__), "ui")
index = os.path.join(ui_dir, "index.html")
assert os.path.isfile(index), f"admin UI missing from installed package: {index}"

print("mlflow                 ", mlflow.__version__)
print("mlflow-oidc-auth       ", md.version("mlflow-oidc-auth"))
print("admin UI               ", ui_dir)
print("psycopg2-binary        ", md.version("psycopg2-binary"))
print("boto3                  ", md.version("boto3"))
print("redis                  ", md.version("redis"))
PY
