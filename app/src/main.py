"""
Finzla backend service — intentionally minimal.

Exposes two endpoints:
  GET /health   liveness/readiness probe consumed by the ALB target group
  GET /version  build provenance, for verifying what is actually deployed

Configuration comes from the environment only. Nothing secret is read at
import time, and no credential is ever logged.
"""

from __future__ import annotations

import logging
import os
import sys
import time
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Any

from fastapi import FastAPI, Response
from fastapi.responses import JSONResponse

# ---------------------------------------------------------------------------
# Configuration (environment only — never hard-coded)
# ---------------------------------------------------------------------------

APP_ENV = os.getenv("APP_ENV", "local")
APP_VERSION = os.getenv("APP_VERSION", "0.0.0-dev")
GIT_SHA = os.getenv("GIT_SHA", "unknown")
BUILD_NUMBER = os.getenv("BUILD_NUMBER", "unknown")
LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO").upper()
PORT = int(os.getenv("PORT", "8000"))

# Set false via env to simulate a failing deployment during the
# troubleshooting exercise. Never set this in production.
READY = os.getenv("SIMULATE_UNHEALTHY", "false").lower() != "true"

START_TIME = time.time()

# ---------------------------------------------------------------------------
# Logging — structured, to stdout/stderr only.
# Container stdout is collected by the awslogs driver; we never write log
# files inside the container.
# ---------------------------------------------------------------------------

logging.basicConfig(
    stream=sys.stdout,
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format='{"ts":"%(asctime)s","level":"%(levelname)s","logger":"%(name)s","msg":"%(message)s"}',
)

# Third-party libraries inherit the root config above. Left at INFO they
# emit a line per outbound HTTP call, which is pure noise and a real cost:
# CloudWatch Logs ingestion is billed per GB. Pin them to WARNING so we pay
# for our own logs, not our dependencies'.
for _noisy in ("httpx", "httpx2", "httpcore", "botocore", "urllib3", "asyncio"):
    logging.getLogger(_noisy).setLevel(logging.WARNING)

log = logging.getLogger("finzla.api")


@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    log.info(
        "service starting env=%s version=%s sha=%s port=%s",
        APP_ENV,
        APP_VERSION,
        GIT_SHA,
        PORT,
    )
    yield
    # Runs on SIGTERM. ECS sends SIGTERM, waits stopTimeout, then SIGKILL —
    # so anything slow here must finish inside that window or be dropped.
    log.info("service shutting down")


app = FastAPI(
    title="Finzla Backend Service",
    version=APP_VERSION,
    lifespan=lifespan,
    # OpenAPI/Swagger disabled in prod: it is free reconnaissance for an
    # attacker and serves no purpose to end customers.
    docs_url=None if APP_ENV == "prod" else "/docs",
    redoc_url=None,
    openapi_url=None if APP_ENV == "prod" else "/openapi.json",
)


@app.get("/health", include_in_schema=False)
async def health() -> Response:
    """
    Returns 200 when the process can serve traffic, 503 otherwise.

    Kept deliberately cheap: the ALB calls this every 15s per task, so it
    must not touch a database or any downstream dependency. A health check
    that depends on a downstream turns a downstream blip into a full outage
    because every target fails at once.
    """
    if not READY:
        log.warning("health check failing: readiness flag is off")
        return JSONResponse(status_code=503, content={"status": "unhealthy"})
    return JSONResponse(status_code=200, content={"status": "ok"})


@app.get("/version")
async def version() -> dict[str, Any]:
    """Build provenance — lets you confirm which commit is actually live."""
    return {
        "version": APP_VERSION,
        "git_sha": GIT_SHA,
        "build_number": BUILD_NUMBER,
        "environment": APP_ENV,
        "uptime_seconds": round(time.time() - START_TIME, 1),
    }


@app.get("/", include_in_schema=False)
async def root() -> dict[str, str]:
    return {"service": "finzla-backend-api", "environment": APP_ENV}
