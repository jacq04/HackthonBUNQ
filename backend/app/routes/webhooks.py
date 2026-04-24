"""Webhook receivers.

POST /webhooks/bunq
  Receives PAYMENT.CREATED events from bunq. Matches each payment to a
  pending contribution row via the description we embedded at request-inquiry
  time, then POSTs the corresponding TB pending transfers.

Also exposes:
POST /webhooks/bunq/replay
  Test-only endpoint that simulates a PAYMENT.CREATED for demo recovery.
"""
from __future__ import annotations

import uuid
from typing import Any

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel

from app.agents.tools import emit_event
from app.bunq.webhooks import extract_payment, verify_webhook_signature
from app.config import settings
from app.db import get_supabase
from app.ledger.tb_two_phase import post_pending, void_pending
from app.routes.contribute import parse_bunq_description
from app.utils.logging import get_logger

log = get_logger(__name__)
router = APIRouter(prefix="/webhooks", tags=["webhooks"])


@router.post("/bunq")
async def receive_bunq_webhook(request: Request) -> dict[str, Any]:
    raw = await request.body()
    sig = request.headers.get("X-Signature")
    if not verify_webhook_signature(raw, sig):
        raise HTTPException(status_code=401, detail="bad signature")

    event = await request.json()
    payment = extract_payment(event)
    if not payment:
        log.info("bunq.webhook.unhandled", shape=list(event.keys()))
        return {"ok": True, "handled": False}

    description = payment.get("description", "")
    parsed = parse_bunq_description(description)
    if not parsed:
        log.info("bunq.webhook.foreign_payment", description=description[:64])
        return {"ok": True, "handled": False}

    return await _commit_contribution(
        group_id=parsed["group_id"],
        user_id=parsed["user_id"],
        cycle_month=parsed["cycle_month"],
        bunq_payment_id=str(payment.get("id") or ""),
        amount_cents=_amount_to_cents(payment.get("amount") or {}),
    )


class ReplayBody(BaseModel):
    group_id: uuid.UUID
    user_id: uuid.UUID
    cycle_month: int = 0
    bunq_payment_id: str = "DEMO-REPLAY"


@router.post("/bunq/replay")
async def replay_webhook(body: ReplayBody) -> dict[str, Any]:
    """Demo-safety valve: force-commit a pending contribution when real bunq webhooks flake."""
    sb = get_supabase()
    c = (
        sb.table("contributions")
        .select("amount_cents")
        .eq("group_id", str(body.group_id))
        .eq("user_id", str(body.user_id))
        .eq("cycle_month", body.cycle_month)
        .eq("status", "pending")
        .order("created_at", desc=True)
        .limit(1)
        .execute()
    )
    amount = int(c.data[0]["amount_cents"]) if c.data else 0
    return await _commit_contribution(
        group_id=body.group_id,
        user_id=body.user_id,
        cycle_month=body.cycle_month,
        bunq_payment_id=body.bunq_payment_id,
        amount_cents=amount,
    )


async def _commit_contribution(
    *,
    group_id: uuid.UUID,
    user_id: uuid.UUID,
    cycle_month: int,
    bunq_payment_id: str,
    amount_cents: int,
) -> dict[str, Any]:
    """Post both TB pending transfers and flip the contributions row to 'posted'."""
    sb = get_supabase()
    c = (
        sb.table("contributions")
        .select("id,tb_pending_pool_id,tb_pending_member_id,status")
        .eq("group_id", str(group_id))
        .eq("user_id", str(user_id))
        .eq("cycle_month", cycle_month)
        .eq("status", "pending")
        .order("created_at", desc=True)
        .limit(1)
        .execute()
    )
    if not c.data:
        log.warning("webhook.no_pending_contribution_found", group_id=str(group_id))
        return {"ok": True, "handled": False, "reason": "no pending row"}

    row = c.data[0]
    pool_pending = int(row["tb_pending_pool_id"])
    member_pending = int(row["tb_pending_member_id"])

    # Post both pending transfers. Do them sequentially for observability.
    post_pending(pool_pending, group_id=group_id, cycle_month=cycle_month)
    post_pending(member_pending, group_id=group_id, cycle_month=cycle_month)

    sb.table("contributions").update(
        {
            "status": "posted",
            "bunq_payment_id": bunq_payment_id,
            "posted_at": "now()",
        }
    ).eq("id", row["id"]).execute()

    await emit_event(
        group_id,
        type="contribution.posted",
        payload={
            "contribution_id": row["id"],
            "user_id": str(user_id),
            "amount_cents": amount_cents,
            "cycle_month": cycle_month,
            "bunq_payment_id": bunq_payment_id,
        },
    )

    return {"ok": True, "handled": True, "contribution_id": row["id"]}


def _amount_to_cents(amount: dict[str, Any]) -> int:
    """bunq returns amount as {value: '12.50', currency: 'EUR'}."""
    try:
        return int(round(float(amount.get("value", "0")) * 100))
    except Exception:  # noqa: BLE001
        return 0
