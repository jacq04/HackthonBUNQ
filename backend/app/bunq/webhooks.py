"""bunq webhook handling.

Inbound events: PAYMENT.CREATED on our joint accounts. We match by description
(which we set at request-inquiry time) to a group_id + member_id and then post
the corresponding TigerBeetle pending transfer.
"""
from __future__ import annotations

import hmac
import hashlib
from typing import Any

from app.config import settings


def verify_webhook_signature(body: bytes, signature_header: str | None) -> bool:
    """HMAC-SHA256 verification. bunq sandbox doesn't strictly sign; we add
    a shared-secret layer for the hackathon's public tunnel.
    """
    if not settings.bunq_webhook_secret:
        return True  # dev mode: accept
    if not signature_header:
        return False
    expected = hmac.new(
        settings.bunq_webhook_secret.encode(), body, hashlib.sha256
    ).hexdigest()
    return hmac.compare_digest(expected, signature_header)


def extract_payment(event: dict[str, Any]) -> dict[str, Any] | None:
    """Pull the Payment object out of a bunq NotificationUrl envelope."""
    obj = event.get("NotificationUrl") or event
    inner = obj.get("object") or {}
    return inner.get("Payment") or inner.get("payment")
