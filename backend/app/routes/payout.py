"""Payout flow — atomic TB linked batch + bunq payment.

POST /groups/{id}/payout/run       Run the current cycle's payout.
POST /groups/{id}/payout/order     Solve + persist the payout ordering.
"""
from __future__ import annotations

import uuid
from typing import Any

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from app.agents.tools import audit, emit_event, post_agent_message
from app.agents.payout_optimizer import MemberPreference, solve_payout_order
from app.auth import CurrentUserId
from app.bunq import get_bunq_client
from app.db import get_supabase
from app.ledger.tb_client import AccountCode, TransferCode, account_id_for
from app.ledger.tb_two_phase import TransferLeg, linked_batch
from app.utils.logging import get_logger

log = get_logger(__name__)
router = APIRouter(prefix="/groups/{group_id}/payout", tags=["payout"])


class SolveOrderBody(BaseModel):
    # Optional overrides — otherwise we read members.payout_cycle (if set) + agent memory.
    preferences: list[dict] | None = None


@router.post("/order")
async def solve_order(
    group_id: uuid.UUID, body: SolveOrderBody, user_id: CurrentUserId
) -> dict[str, Any]:
    sb = get_supabase()
    g = sb.table("groups").select("cycle_count").eq("id", str(group_id)).single().execute()
    if not g.data:
        raise HTTPException(status_code=404, detail="group not found")
    n_cycles = int(g.data["cycle_count"])

    members = (
        sb.table("members")
        .select("user_id,payout_cycle,status")
        .eq("group_id", str(group_id))
        .eq("status", "active")
        .execute()
    )
    if not members.data or len(members.data) != n_cycles:
        raise HTTPException(
            status_code=400,
            detail=f"need exactly {n_cycles} active members (got {len(members.data or [])})",
        )

    prefs = [
        MemberPreference(
            user_id=m["user_id"],
            preferred_month=m.get("payout_cycle"),
            urgency=1,
        )
        for m in members.data
    ]
    if body.preferences:
        override = {p["user_id"]: p for p in body.preferences}
        prefs = [
            MemberPreference(
                user_id=p.user_id,
                preferred_month=override.get(p.user_id, {}).get("preferred_month", p.preferred_month),
                urgency=override.get(p.user_id, {}).get("urgency", p.urgency),
            )
            for p in prefs
        ]

    assignments = solve_payout_order(prefs, n_cycles=n_cycles)
    for a in assignments:
        sb.table("members").update({"payout_cycle": a.assigned_month}).eq(
            "group_id", str(group_id)
        ).eq("user_id", a.user_id).execute()

    await emit_event(
        group_id,
        type="payout.order_solved",
        payload={"assignments": [{"user_id": a.user_id, "month": a.assigned_month} for a in assignments]},
    )
    return {"assignments": [a.__dict__ for a in assignments]}


class RunPayoutBody(BaseModel):
    cycle_month: int = Field(ge=1, le=24)
    bunq_recipient_iban: str | None = None
    bunq_recipient_name: str | None = None


@router.post("/run")
async def run_payout(
    group_id: uuid.UUID, body: RunPayoutBody, user_id: CurrentUserId
) -> dict[str, Any]:
    sb = get_supabase()
    g = sb.table("groups").select("*").eq("id", str(group_id)).single().execute()
    if not g.data:
        raise HTTPException(status_code=404, detail="group not found")
    group = g.data

    # Recipient is whoever is assigned to this cycle_month.
    recipient = (
        sb.table("members")
        .select("user_id,tb_received_account_id,users(display_name)")
        .eq("group_id", str(group_id))
        .eq("payout_cycle", body.cycle_month)
        .eq("status", "active")
        .single()
        .execute()
    )
    if not recipient.data:
        raise HTTPException(
            status_code=400,
            detail=f"no member assigned to cycle {body.cycle_month}",
        )

    pot_cents = int(group["contribution_amount_cents"]) * int(group["cycle_count"])

    # Atomic TB linked batch: pool -> gateway (release), pool -> member_received.
    pool = int(group["tb_pool_account_id"])
    gateway = int(group["tb_gateway_account_id"])
    member_received = int(recipient.data["tb_received_account_id"])

    tb_ids = linked_batch(
        [
            TransferLeg(pool, gateway, pot_cents, TransferCode.PAYOUT),
            TransferLeg(pool, member_received, pot_cents, TransferCode.PAYOUT),
        ],
        group_id=group_id,
        cycle_month=body.cycle_month,
    )

    # bunq payment to the recipient (best-effort).
    bunq_payment_id: str | None = None
    if group.get("bunq_account_id") and body.bunq_recipient_iban and body.bunq_recipient_name:
        try:
            resp = await get_bunq_client().make_payment(
                from_account_id=int(group["bunq_account_id"]),
                amount_cents=pot_cents,
                counterparty_iban=body.bunq_recipient_iban,
                counterparty_name=body.bunq_recipient_name,
                description=f"Kitty payout cycle {body.cycle_month}",
                currency=group["currency"],
            )
            bunq_payment_id = str(resp.get("id") or "")
        except Exception as e:  # noqa: BLE001
            log.warning("payout.bunq_failed", error=str(e))

    # Persist payouts row.
    payout_id = str(uuid.uuid4())
    sb.table("payouts").insert(
        {
            "id": payout_id,
            "group_id": str(group_id),
            "recipient_user_id": recipient.data["user_id"],
            "cycle_month": body.cycle_month,
            "amount_cents": pot_cents,
            "tb_transfer_ids": [str(x) for x in tb_ids],
            "bunq_payment_id": bunq_payment_id,
            "status": "committed" if bunq_payment_id else "pending",
            "committed_at": "now()" if bunq_payment_id else None,
        }
    ).execute()

    await emit_event(
        group_id,
        type="payout.committed" if bunq_payment_id else "payout.ledger_only",
        payload={
            "payout_id": payout_id,
            "recipient_user_id": recipient.data["user_id"],
            "cycle_month": body.cycle_month,
            "amount_cents": pot_cents,
            "tb_transfer_ids": [str(x) for x in tb_ids],
            "bunq_payment_id": bunq_payment_id,
        },
    )
    await audit(
        actor=f"user:{user_id}",
        action="payout.run",
        resource_type="payout",
        resource_id=payout_id,
        diff={"cycle_month": body.cycle_month, "amount_cents": pot_cents},
    )
    # Agent message announcing the payout.
    await post_agent_message(
        group_id,
        agent_name="system",
        text=f"Cycle {body.cycle_month} payout of €{pot_cents/100:.2f} to "
             f"{recipient.data['users']['display_name']} — pot atomic transfer complete.",
    )

    return {
        "payout_id": payout_id,
        "amount_cents": pot_cents,
        "tb_transfer_ids": [str(x) for x in tb_ids],
        "bunq_payment_id": bunq_payment_id,
    }
