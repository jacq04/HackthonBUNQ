"""Request auth — extract the current user from a Supabase JWT."""
from __future__ import annotations

import uuid
from typing import Annotated

from fastapi import Depends, HTTPException, Request, status

from app.db import get_supabase
from app.utils.logging import get_logger

log = get_logger(__name__)


async def current_user_id(request: Request) -> uuid.UUID:
    token = _bearer_token(request)
    if not token:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Missing token")
    try:
        sb = get_supabase()
        resp = sb.auth.get_user(token)
        user = resp.user
        if not user or not user.id:
            raise ValueError("no user in token")
        return uuid.UUID(user.id)
    except Exception as e:  # noqa: BLE001
        log.warning("auth.invalid_token", error=str(e))
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid token") from e


def _bearer_token(request: Request) -> str | None:
    auth = request.headers.get("Authorization", "")
    if auth.lower().startswith("bearer "):
        return auth[7:].strip()
    return None


CurrentUserId = Annotated[uuid.UUID, Depends(current_user_id)]
