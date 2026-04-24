from __future__ import annotations

from fastapi import APIRouter

router = APIRouter(prefix="/health", tags=["meta"])


@router.get("")
async def health() -> dict[str, str]:
    return {"status": "ok", "service": "kitty"}
