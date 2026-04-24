"""Signed group-invite tokens — no DB table needed.

Payload: {g: group_id, exp: unix_ts}
Signed with HMAC-SHA256 using PASSPORT_HMAC_SECRET (shared with passport signer).
Encoded as base64url for QR-safe representation.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import time
import uuid

from app.config import settings

_TTL_SECONDS = 60 * 60 * 24 * 7  # 7 days


def _b64e(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def _b64d(data: str) -> bytes:
    pad = "=" * (-len(data) % 4)
    return base64.urlsafe_b64decode(data + pad)


def _sign(payload: bytes) -> bytes:
    return hmac.new(settings.passport_hmac_secret.encode(), payload, hashlib.sha256).digest()


def make_invite(group_id: uuid.UUID, *, ttl_seconds: int = _TTL_SECONDS) -> str:
    body = json.dumps({"g": str(group_id), "exp": int(time.time()) + ttl_seconds}).encode()
    sig = _sign(body)
    return f"{_b64e(body)}.{_b64e(sig)}"


def verify_invite(token: str) -> uuid.UUID:
    try:
        body_b64, sig_b64 = token.split(".", 1)
        body = _b64d(body_b64)
        sig = _b64d(sig_b64)
    except Exception as e:  # noqa: BLE001
        raise ValueError("malformed invite") from e

    expected = _sign(body)
    if not hmac.compare_digest(expected, sig):
        raise ValueError("invalid invite signature")

    data = json.loads(body)
    if int(data["exp"]) < int(time.time()):
        raise ValueError("invite expired")
    return uuid.UUID(data["g"])
