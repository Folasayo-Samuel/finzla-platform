# syntax=docker/dockerfile:1
#
# Multi-stage build.
#
# Stage 1 installs dependencies into a virtualenv using the full slim image
# (which has the compilers some wheels need). Stage 2 copies only that
# virtualenv plus source into a fresh image, so no build toolchain, package
# index cache, or pip itself ships to production.
#
# Base image is referenced by tag here for readability. BEFORE PRODUCTION,
# pin it by digest — a tag is mutable, so `python:3.13-slim` can resolve to
# different bytes tomorrow, which breaks reproducibility and lets an upstream
# compromise reach you silently. Get the digest with:
#
#   docker pull python:3.13-slim
#   docker inspect --format='{{index .RepoDigests 0}}' python:3.13-slim
#
# then replace both FROM lines with python:3.13-slim@sha256:<digest>.

# ---------------------------------------------------------------------------
# Stage 1 — build dependencies
# ---------------------------------------------------------------------------
FROM python:3.13-slim AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /build

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Copy only the manifest first so this layer caches independently of source
# changes. Editing main.py should not trigger a dependency reinstall.
COPY requirements.txt .
RUN pip install -r requirements.txt

# ---------------------------------------------------------------------------
# Stage 2 — runtime
# ---------------------------------------------------------------------------
FROM python:3.13-slim AS runtime

# Build metadata, injected by CI. These are the only values that change per
# build, and they sit at the end of the file so earlier layers stay cached.
ARG APP_VERSION="0.0.0-dev"
ARG GIT_SHA="unknown"
ARG BUILD_NUMBER="unknown"

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH" \
    APP_VERSION=${APP_VERSION} \
    GIT_SHA=${GIT_SHA} \
    BUILD_NUMBER=${BUILD_NUMBER} \
    PORT=8000

# Patch the base OS, then drop the package manager cache in the same layer
# so the cache never lands in the image.
RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*

# Dedicated unprivileged user. A container escape from root inside the
# container is materially worse than one from uid 10001.
RUN groupadd --gid 10001 appuser \
    && useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin appuser

WORKDIR /app

COPY --from=builder /opt/venv /opt/venv
COPY --chown=10001:10001 src/ ./src/

USER 10001:10001

EXPOSE 8000

# ECS uses the ALB target group for routing decisions, but a container-level
# HEALTHCHECK still helps locally and gives ECS an earlier signal.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health', timeout=2).status==200 else 1)"

# exec form — no shell wrapper, so the process is PID 1 and receives
# SIGTERM directly. Without this, ECS task draining waits the full timeout.
CMD ["uvicorn", "src.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "2", "--access-log", "--no-server-header"]
