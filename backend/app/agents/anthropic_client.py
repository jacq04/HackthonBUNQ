"""Shared Anthropic client."""
from __future__ import annotations

from functools import lru_cache

from anthropic import AsyncAnthropic

from app.config import settings


@lru_cache
def get_claude() -> AsyncAnthropic:
    if not settings.anthropic_api_key:
        raise RuntimeError("ANTHROPIC_API_KEY is not configured")
    return AsyncAnthropic(api_key=settings.anthropic_api_key)
