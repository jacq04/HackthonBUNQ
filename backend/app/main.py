"""Kitty FastAPI app entry point."""
from __future__ import annotations

from contextlib import asynccontextmanager
from collections.abc import AsyncIterator

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.bunq import get_bunq_client
from app.config import settings
from app.routes import (
    auth_bunq,
    charter,
    chat,
    circle_lifecycle,
    contribute,
    cycles,
    disputes,
    emergency,
    groups,
    health,
    invites,
    matchmaker,
    members,
    payout,
    webhooks,
)
from app.utils.logging import configure_logging, get_logger

log = get_logger(__name__)


@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    configure_logging()
    log.info("kitty.starting", env=settings.env, port=settings.backend_port)
    # Warm bunq session lazily on first request — avoids blocking startup when
    # keys aren't set yet (common in dev). We still register the cleanup hook.
    try:
        yield
    finally:
        try:
            await get_bunq_client().close()
        except Exception as e:  # noqa: BLE001
            log.warning("kitty.shutdown.bunq_close_failed", error=str(e))


app = FastAPI(
    title="Kitty",
    description="ROSCA orchestrator for the bunq Hackathon 7.0",
    version="0.1.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # hackathon; tighten before production
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Routers — registered lazily so a missing dep in one route doesn't sink the app.
app.include_router(health.router)
app.include_router(auth_bunq.router)
app.include_router(groups.router)
app.include_router(members.router)
app.include_router(matchmaker.router)
app.include_router(invites.router)
app.include_router(circle_lifecycle.router)
app.include_router(cycles.router)
app.include_router(charter.router)
app.include_router(chat.router)
app.include_router(contribute.router)
app.include_router(payout.router)
app.include_router(disputes.router)
app.include_router(emergency.router)
app.include_router(webhooks.router)


@app.get("/", tags=["meta"])
async def root() -> dict[str, str]:
    return {
        "app": "kitty",
        "tagline": "bunq = bank, TigerBeetle = accountant, Claude = organizer",
        "docs": "/docs",
    }
