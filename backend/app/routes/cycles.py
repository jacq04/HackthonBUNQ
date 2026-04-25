"""Cycle + bid routes.

    POST   /groups/{gid}/cycles/{month}/bid      member places or replaces a bid
    DELETE /groups/{gid}/cycles/{month}/bid      member withdraws own bid
    POST   /groups/{gid}/cycles/{month}/resolve  admin/scheduler: close bid window,
                                                 invoke Bidding agent or fallback,
                                                 execute payout via routes/payout.run_payout

Winner-source flow:
  bids==0 → fallback: member with earliest unreceived payout_cycle wins
  bids==1 → short-circuit: that bidder wins (no agent)
  bids>=2 → Bidding agent resolves
"""
from __future__ import annotations

import uuid
from datetime import datetime, timezone
from typing import Any, Literal

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from app.agents.bidding import get_bidding
from app.agents.tools import audit, emit_event, post_agent_message
from app.auth import CurrentUserId
from app.db import get_supabase
from app.ledger.tb_client import (
    AccountCode,
    TransferCode,
    account_id_for,
    lookup_balance,
)
from app.ledger.tb_two_phase import TransferLeg, linked_batch
from app.utils.logging import get_logger

log = get_logger(__name__)
router = APIRouter(prefix="/groups/{group_id}/cycles", tags=["cycles"])


# ─────────────────────────────────────────────────────────────────────────────
# Bid CRUD
# ─────────────────────────────────────────────────────────────────────────────
class BidBody(BaseModel):
    urgency: Literal["low", "medium", "high", "critical"]
    reason: str = Field(min_length=10, max_length=500)


class BidResponse(BaseModel):
    bid_id: uuid.UUID
    cycle_id: uuid.UUID
    urgency: str
    reason: str


@router.post("/{cycle_month}/bid", response_model=BidResponse)
async def place_bid(
    group_id: uuid.UUID,
    cycle_month: int,
    body: BidBody,
    user_id: CurrentUserId,
) -> BidResponse:
    sb = get_supabase()

    # Member must be active (has accepted + not received + not exited).
    me = (
        sb.table("members")
        .select("status,payout_cycle")
        .eq("group_id", str(group_id))
        .eq("user_id", str(user_id))
        .maybe_single()
        .execute()
    )
    if not me or not me.data or me.data["status"] != "active":
        raise HTTPException(
            status_code=403, detail="only active members can bid"
        )

    # Cycle must be open for bidding.
    cycle = (
        sb.table("cycles")
        .select("*")
        .eq("group_id", str(group_id))
        .eq("cycle_month", cycle_month)
        .maybe_single()
        .execute()
    )
    if not cycle or not cycle.data:
        raise HTTPException(status_code=404, detail="cycle not found")
    c = cycle.data
    if c["status"] not in ("contribution_window", "bid_window"):
        raise HTTPException(
            status_code=409,
            detail=f"cycle status is {c['status']}, not accepting bids",
        )

    # One bid per (cycle, user) — upsert.
    existing = (
        sb.table("bids")
        .select("id")
        .eq("cycle_id", c["id"])
        .eq("user_id", str(user_id))
        .maybe_single()
        .execute()
    )
    if existing and existing.data:
        sb.table("bids").update(
            {
                "urgency": body.urgency,
                "reason": body.reason,
                "withdrawn_at": None,
                "reason_score": None,
                "weight": None,
            }
        ).eq("id", existing.data["id"]).execute()
        bid_id = uuid.UUID(existing.data["id"])
    else:
        bid_id = uuid.uuid4()
        sb.table("bids").insert(
            {
                "id": str(bid_id),
                "cycle_id": c["id"],
                "user_id": str(user_id),
                "urgency": body.urgency,
                "reason": body.reason,
            }
        ).execute()

    # Flip cycle into bid_window if we were still in the contribution window.
    if c["status"] == "contribution_window":
        sb.table("cycles").update({"status": "bid_window"}).eq("id", c["id"]).execute()

    await emit_event(
        group_id,
        type="bid.placed",
        payload={
            "cycle_id": c["id"],
            "cycle_month": cycle_month,
            "user_id": str(user_id),
            "urgency": body.urgency,
        },
    )
    await audit(
        actor=f"user:{user_id}",
        action="bid.place",
        resource_type="cycle",
        resource_id=c["id"],
        diff={"urgency": body.urgency, "reason": body.reason},
    )

    return BidResponse(
        bid_id=bid_id,
        cycle_id=uuid.UUID(c["id"]),
        urgency=body.urgency,
        reason=body.reason,
    )


@router.delete("/{cycle_month}/bid")
async def withdraw_bid(
    group_id: uuid.UUID, cycle_month: int, user_id: CurrentUserId
) -> dict[str, Any]:
    sb = get_supabase()
    cycle = (
        sb.table("cycles")
        .select("id,status")
        .eq("group_id", str(group_id))
        .eq("cycle_month", cycle_month)
        .maybe_single()
        .execute()
    )
    if not cycle or not cycle.data:
        raise HTTPException(status_code=404, detail="cycle not found")
    if cycle.data["status"] not in ("contribution_window", "bid_window"):
        raise HTTPException(status_code=409, detail="bid window closed")
    sb.table("bids").update(
        {"withdrawn_at": datetime.now(timezone.utc).isoformat()}
    ).eq("cycle_id", cycle.data["id"]).eq("user_id", str(user_id)).execute()
    return {"ok": True}


# ─────────────────────────────────────────────────────────────────────────────
# Resolve a cycle — bidding agent OR fallback → TB payout
# ─────────────────────────────────────────────────────────────────────────────
@router.post("/{cycle_month}/resolve")
async def resolve_cycle(
    group_id: uuid.UUID, cycle_month: int, user_id: CurrentUserId
) -> dict[str, Any]:
    sb = get_supabase()
    group = sb.table("groups").select("*").eq("id", str(group_id)).single().execute().data
    cycle = (
        sb.table("cycles")
        .select("*")
        .eq("group_id", str(group_id))
        .eq("cycle_month", cycle_month)
        .single()
        .execute()
        .data
    )
    if cycle["status"] == "paid":
        raise HTTPException(status_code=409, detail="cycle already paid")

    bids = (
        sb.table("bids")
        .select("id,user_id,urgency,reason,users!inner(display_name)")
        .eq("cycle_id", cycle["id"])
        .is_("withdrawn_at", "null")
        .execute()
        .data
        or []
    )

    winner_user_id: str | None = None
    winner_source: str
    rationale: str

    if len(bids) == 0:
        # Fallback — earliest unreceived payout_cycle.
        next_recipient = (
            sb.table("members")
            .select("user_id,payout_cycle,users!inner(display_name)")
            .eq("group_id", str(group_id))
            .eq("status", "active")
            .order("payout_cycle")
            .limit(1)
            .execute()
            .data
        )
        if not next_recipient:
            raise HTTPException(status_code=409, detail="no eligible recipient")
        winner_user_id = next_recipient[0]["user_id"]
        winner_source = "fallback"
        rationale = (
            f"No bids this cycle — scheduled slot "
            f"{next_recipient[0]['payout_cycle']} wins by Payout-Optimizer fallback."
        )
        sb.table("cycles").update(
            {
                "winner_user_id": winner_user_id,
                "winner_source": "fallback",
                "winner_rationale": rationale,
                "status": "resolving",
            }
        ).eq("id", cycle["id"]).execute()

    elif len(bids) == 1:
        only = bids[0]
        winner_user_id = only["user_id"]
        winner_source = "bid"
        rationale = (
            f"Sole bid by {only['users']['display_name']} "
            f"(urgency={only['urgency']}) — no contest."
        )
        sb.table("bids").update({"reason_score": 100, "weight": 1.0}).eq(
            "id", only["id"]
        ).execute()
        sb.table("cycles").update(
            {
                "winner_user_id": winner_user_id,
                "winner_source": "bid",
                "winner_rationale": rationale,
                "status": "resolving",
            }
        ).eq("id", cycle["id"]).execute()

    else:
        # 2+ bids → Bidding agent.
        agent_result = await get_bidding().run(
            (
                f"Cycle {cycle_month} of group {group['name']} has {len(bids)} bids. "
                f"Follow the 3-tool process: list_bids → evaluate_bid (once per bid) → "
                f"select_winner. cycle_id={cycle['id']} group_id={group_id}."
            ),
            context={"cycle_id": uuid.UUID(cycle["id"]), "group_id": group_id},
        )
        # The agent wrote winner_user_id + winner_source='bid' via select_winner tool.
        cycle_after = (
            sb.table("cycles")
            .select("winner_user_id,winner_rationale")
            .eq("id", cycle["id"])
            .single()
            .execute()
            .data
        )
        winner_user_id = cycle_after.get("winner_user_id")
        winner_source = "bid"
        rationale = cycle_after.get("winner_rationale") or agent_result.text

    if not winner_user_id:
        raise HTTPException(
            status_code=500, detail="failed to determine winner"
        )

    # ── Execute payout via TB linked batch (same shape as routes/payout.run_payout).
    pool_cents = int(group["contribution_amount_cents"]) * int(group["cycle_count"])
    winner_member = (
        sb.table("members")
        .select("tb_received_account_id,users!inner(display_name)")
        .eq("group_id", str(group_id))
        .eq("user_id", winner_user_id)
        .single()
        .execute()
        .data
    )
    gateway = int(group["tb_gateway_account_id"])
    pool = int(group["tb_pool_account_id"])
    member_received = int(winner_member["tb_received_account_id"])

    # Payout leaves the pool ONCE (via gateway). The second leg tracks the
    # winner's accrual on their received account — debit-side now on gateway,
    # not on pool again (that would trip debits_must_not_exceed_credits).
    transfer_code = TransferCode.BID_WON if winner_source == "bid" else TransferCode.PAYOUT_FALLBACK
    tb_ids = linked_batch(
        [
            TransferLeg(pool, gateway, pool_cents, transfer_code),
            TransferLeg(gateway, member_received, pool_cents, transfer_code),
        ],
        group_id=group_id,
        cycle_month=cycle_month,
    )

    payout_row_id = str(uuid.uuid4())
    sb.table("payouts").insert(
        {
            "id": payout_row_id,
            "group_id": str(group_id),
            "recipient_user_id": winner_user_id,
            "cycle_month": cycle_month,
            "amount_cents": pool_cents,
            "tb_transfer_ids": [str(x) for x in tb_ids],
            "status": "pending",
        }
    ).execute()
    sb.table("cycles").update(
        {"status": "paid", "payout_at": datetime.now(timezone.utc).isoformat()}
    ).eq("id", cycle["id"]).execute()
    sb.table("members").update(
        {"status": "received", "received_at": datetime.now(timezone.utc).isoformat()}
    ).eq("group_id", str(group_id)).eq("user_id", winner_user_id).execute()

    # Advance the next scheduled cycle into the contribution window.
    nxt = (
        sb.table("cycles")
        .select("id")
        .eq("group_id", str(group_id))
        .eq("cycle_month", cycle_month + 1)
        .maybe_single()
        .execute()
    )
    if nxt and nxt.data:
        sb.table("cycles").update({"status": "contribution_window"}).eq(
            "id", nxt.data["id"]
        ).execute()
    else:
        # Last cycle — mark group completed.
        sb.table("groups").update({"status": "completed"}).eq(
            "id", str(group_id)
        ).execute()
        await emit_event(group_id, type="group.completed", payload={})

    await emit_event(
        group_id,
        type="bid.resolved" if winner_source == "bid" else "payout.ledger_only",
        payload={
            "cycle_id": cycle["id"],
            "cycle_month": cycle_month,
            "winner_user_id": winner_user_id,
            "winner_display_name": winner_member["users"]["display_name"],
            "winner_source": winner_source,
            "amount_cents": pool_cents,
            "rationale": rationale,
            "tb_transfer_ids": [str(x) for x in tb_ids],
        },
    )
    await post_agent_message(
        group_id,
        agent_name="bidding",
        text=rationale,
        metadata={
            "cycle_month": cycle_month,
            "winner_user_id": winner_user_id,
            "winner_source": winner_source,
        },
    )

    return {
        "ok": True,
        "cycle_month": cycle_month,
        "winner_user_id": winner_user_id,
        "winner_display_name": winner_member["users"]["display_name"],
        "winner_source": winner_source,
        "amount_cents": pool_cents,
        "rationale": rationale,
    }
