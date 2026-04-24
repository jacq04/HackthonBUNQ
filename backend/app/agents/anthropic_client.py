"""Shared Anthropic client."""
from __future__ import annotations

from functools import lru_cache

import httpx
from anthropic import AsyncAnthropic

from app.config import settings
from app.utils.tls import make_ssl_context


@lru_cache
def get_claude() -> AsyncAnthropic:
    if not settings.anthropic_api_key:
        raise RuntimeError("ANTHROPIC_API_KEY is not configured")
    # Pass a pre-configured httpx client so corporate-CA setups (Netskope etc.)
    # work without patching site-packages. In clean environments the same
    # context still falls through to certifi's Mozilla bundle.
    http_client = httpx.AsyncClient(verify=make_ssl_context(), timeout=60.0)
    return AsyncAnthropic(api_key=settings.anthropic_api_key, http_client=http_client)
