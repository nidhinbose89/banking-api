import logging
import os
import time

from fastapi import FastAPI, Request

from app.logging_config import configure_logging
from app.routers import accounts

configure_logging()
logger = logging.getLogger(__name__)

app = FastAPI()

app.include_router(accounts.router)


@app.get("/")
def root() -> dict[str, str]:
    return {
        "name": "Banking API",
        "description": "REST API for basic banking operations",
        "docs": "/docs",
        "health": "/health",
        "version": "/version",
    }


@app.middleware("http")
async def log_requests(request: Request, call_next):
    start_time = time.perf_counter()
    response = await call_next(request)
    duration_ms = round((time.perf_counter() - start_time) * 1000, 2)
    status_code = response.status_code

    extra = {
        "method": request.method,
        "path": request.url.path,
        "status_code": status_code,
        "duration_ms": duration_ms,
        "client_host": request.client.host if request.client else None,
    }
    if status_code >= 500:
        logger.error("http_request", extra=extra)
    elif status_code >= 400:
        logger.warning("http_request", extra=extra)
    else:
        logger.info("http_request", extra=extra)

    return response


@app.get("/health")
def health_check() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/version")
def version() -> dict[str, str]:
    return {
        "version": os.getenv("APP_VERSION", "unknown"),
        "deployed_at": os.getenv("BUILD_TIME", "unknown"),
    }
