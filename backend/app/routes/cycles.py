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
from app.bunq import get_bunq_client
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

    # ── Compute the split: winner gets (1 - fee_bps/10000), platform retains rest.
    from app.config import settings

    pool_cents = int(group["contribution_amount_cents"]) * int(group["cycle_count"])
    fee_bps = int(settings.payout_admin_fee_bps)
    fee_cents = (pool_cents * fee_bps) // 10000
    winner_cents = pool_cents - fee_cents

    winner_member = (
        sb.table("members")
        .select(
            "tb_received_account_id,"
            "users!inner(display_name,bunq_label)"
        )
        .eq("group_id", str(group_id))
        .eq("user_id", winner_user_id)
        .single()
        .execute()
        .data
    )
    gateway = int(group["tb_gateway_account_id"])
    pool = int(group["tb_pool_account_id"])
    penalty = int(group["tb_penalty_account_id"])
    member_received = int(winner_member["tb_received_account_id"])

    # Atomic 3-leg linked batch:
    #   1. pool → gateway: full pot release (the only debit on pool — invariant intact)
    #   2. gateway → member_received: winner's 95% accrual
    #   3. gateway → penalty_pool: 5% admin fee retention
    # The penalty_pool account is reused as the per-group fee bucket; the
    # ledger trail makes the split auditable. All three legs commit or none do.
    transfer_code = TransferCode.BID_WON if winner_source == "bid" else TransferCode.PAYOUT_FALLBACK
    legs: list[TransferLeg] = [
        TransferLeg(pool, gateway, pool_cents, transfer_code),
        TransferLeg(gateway, member_received, winner_cents, transfer_code),
    ]
    if fee_cents > 0:
        legs.append(
            TransferLeg(gateway, penalty, fee_cents, transfer_code)
        )
    tb_ids = linked_batch(
        legs,
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
            # amount_cents is what the winner actually receives — the 5%
            # platform fee stays on the platform's bunq + ledger, never paid out.
            "amount_cents": winner_cents,
            "tb_transfer_ids": [str(x) for x in tb_ids],
            "status": "pending",
        }
    ).execute()

    # ── Real-money leg: platform.bunq → winner.bunq for `winner_cents`.
    # Best-effort — if it fails, TB stays the source of truth and the event
    # downgrades to payout.ledger_only.
    bunq_payment_id: str | None = None
    bunq_error: str | None = None
    bunq_suspension: dict | None = None
    winner_bunq_label = (winner_member.get("users") or {}).get("bunq_label")
    try:
        platform_client = get_bunq_client(settings.bunq_platform_label)
        await platform_client.ensure_session()
        platform_acct_id = await platform_client.get_primary_account_id()

        # Resolve the winner's IBAN — first from their stored mandate, then by
        # asking bunq directly if their session is provisioned on this host.
        winner_iban: str | None = None
        winner_name: str | None = (winner_member.get("users") or {}).get("display_name")
        mandate = (
            sb.table("mandates")
            .select("iban")
            .eq("group_id", str(group_id))
            .eq("user_id", winner_user_id)
            .eq("status", "active")
            .order("signed_at", desc=True)
            .limit(1)
            .execute()
            .data
        )
        if mandate and mandate[0].get("iban"):
            winner_iban = mandate[0]["iban"]
        if not winner_iban and winner_bunq_label:
            try:
                wc = get_bunq_client(winner_bunq_label)
                await wc.ensure_session()
                w_acct_id = await wc.get_primary_account_id()
                for a in await wc.list_monetary_accounts():
                    if a.get("id") == w_acct_id:
                        for alias in a.get("alias") or []:
                            if alias.get("type") == "IBAN":
                                winner_iban = alias.get("value")
                                break
                        break
            except Exception as e:  # noqa: BLE001
                log.warning(
                    "payout.winner_iban_lookup_failed",
                    label=winner_bunq_label,
                    error=str(e),
                )

        if not winner_iban or not winner_name:
            raise RuntimeError("winner IBAN/name unavailable — bunq leg skipped")

        pay = await platform_client.make_payment(
            from_account_id=platform_acct_id,
            amount_cents=winner_cents,
            counterparty_iban=winner_iban,
            counterparty_name=winner_name,
            description=(
                f"Kitty · {group['name']} · cycle {cycle_month} payout "
                f"(net of {fee_bps/100:.1f}% fee)"
            ),
            currency=group["currency"],
        )
        bunq_payment_id = str(pay.get("id") or "") or None
        if bunq_payment_id:
            # GET the payment back to inspect `payment_suspended_outgoing` —
            # it's only populated on the read, never on the POST. bunq holds
            # any first-time payment to a NEW_COUNTERPARTY for ~24h before
            # the credit actually posts on the recipient's side.
            try:
                detail = await platform_client.get_payment(
                    account_id=platform_acct_id,
                    payment_id=int(bunq_payment_id),
                )
                bunq_suspension = detail.get("payment_suspended_outgoing")
            except Exception as e:  # noqa: BLE001
                log.warning("payout.bunq_get_failed", error=str(e))
                bunq_suspension = None

            if bunq_suspension and (bunq_suspension.get("status") or "").upper() == "PENDING":
                # Funds earmarked on the sender, recipient not yet credited.
                sb.table("payouts").update(
                    {
                        "bunq_payment_id": bunq_payment_id,
                        "status": "suspended",
                        # committed_at deliberately stays null — the payment
                        # hasn't actually settled yet.
                    }
                ).eq("id", payout_row_id).execute()
            else:
                sb.table("payouts").update(
                    {
                        "bunq_payment_id": bunq_payment_id,
                        "status": "committed",
                        "committed_at": datetime.now(timezone.utc).isoformat(),
                    }
                ).eq("id", payout_row_id).execute()
    except Exception as e:  # noqa: BLE001
        bunq_error = str(e)
        log.warning("payout.bunq_failed", error=bunq_error)
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

    # bunq leg outcome:
    #   - bunq_payment_id + PENDING suspension → payout.bunq_suspended
    #   - bunq_payment_id, no suspension       → payout.committed
    #   - no bunq_payment_id                   → payout.ledger_only
    is_suspended = bool(
        bunq_suspension
        and (bunq_suspension.get("status") or "").upper() == "PENDING"
    )
    if is_suspended:
        settled_event_type = "payout.bunq_suspended"
    elif bunq_payment_id:
        settled_event_type = "payout.committed"
    else:
        settled_event_type = "payout.ledger_only"
    suspension_summary = None
    if bunq_suspension:
        suspension_summary = {
            "status": bunq_suspension.get("status"),
            "reason": bunq_suspension.get("reason"),
            "expected_arrival": (
                (bunq_suspension.get("payment_arrival_expected") or {}).get("time")
            ),
            "time_execution": bunq_suspension.get("time_execution"),
            "suspended_id": bunq_suspension.get("id"),
        }
    await emit_event(
        group_id,
        type=settled_event_type,
        payload={
            "cycle_id": cycle["id"],
            "cycle_month": cycle_month,
            "winner_user_id": winner_user_id,
            "winner_display_name": winner_member["users"]["display_name"],
            "winner_source": winner_source,
            "pot_cents": pool_cents,
            "amount_cents": winner_cents,
            "fee_cents": fee_cents,
            "fee_bps": fee_bps,
            "rationale": rationale,
            "bunq_payment_id": bunq_payment_id,
            "bunq_error": bunq_error,
            "bunq_suspension": suspension_summary,
            "tb_transfer_ids": [str(x) for x in tb_ids],
        },
    )
    if winner_source == "bid":
        await emit_event(
            group_id,
            type="bid.resolved",
            payload={
                "cycle_id": cycle["id"],
                "cycle_month": cycle_month,
                "winner_user_id": winner_user_id,
                "winner_display_name": winner_member["users"]["display_name"],
                "rationale": rationale,
            },
        )
    fee_eur = fee_cents / 100
    win_eur = winner_cents / 100
    if is_suspended:
        suspension_reason = (suspension_summary or {}).get("reason") or "PENDING"
        expected_arrival = (suspension_summary or {}).get("expected_arrival") or "soon"
        bunq_tail = (
            f" · bunq holding payment #{bunq_payment_id} ({suspension_reason}) "
            f"— credit expected {expected_arrival}"
        )
    elif bunq_payment_id:
        bunq_tail = f" · paid via bunq (#{bunq_payment_id})"
    else:
        bunq_tail = " · ledger-only (bunq leg pending)"
    await post_agent_message(
        group_id,
        agent_name="bidding",
        text=(
            f"{rationale} Winner receives €{win_eur:.2f} "
            f"(€{fee_eur:.2f} retained as {fee_bps/100:.1f}% admin fee).{bunq_tail}"
        ),
        metadata={
            "cycle_month": cycle_month,
            "winner_user_id": winner_user_id,
            "winner_source": winner_source,
            "winner_amount_cents": winner_cents,
            "fee_cents": fee_cents,
            "bunq_payment_id": bunq_payment_id,
        },
    )

    # ── Regret notifications: 2+ bids, one winner — message every loser
    # privately so they see the outcome in their feed and know they're queued
    # for the next cycle. Single bidder + fallback paths skip this (nothing
    # to regret). All sends are best-effort — failures shouldn't roll back
    # the payout that already committed.
    if len(bids) >= 2:
        winner_name = winner_member["users"]["display_name"]
        regretted: list[str] = []
        for b in bids:
            loser_id = b["user_id"]
            if loser_id == winner_user_id:
                continue
            loser_name = (b.get("users") or {}).get("display_name") or "there"
            try:
                await post_agent_message(
                    group_id,
                    agent_name="bidding",
                    channel="direct",
                    recipient_user_id=loser_id,
                    text=(
                        f"Hi {loser_name} — cycle {cycle_month} went to "
                        f"{winner_name} this round. Your bid "
                        f"(urgency: {b.get('urgency')}) was considered but "
                        f"didn't win. The pot rolls — bid again next cycle, "
                        f"or wait for your scheduled slot."
                    ),
                    metadata={
                        "cycle_month": cycle_month,
                        "winner_user_id": winner_user_id,
                        "winner_display_name": winner_name,
                        "your_bid_id": b["id"],
                        "your_urgency": b.get("urgency"),
                        "kind": "bid.regret",
                    },
                )
                await emit_event(
                    group_id,
                    type="bid.regret",
                    payload={
                        "cycle_id": cycle["id"],
                        "cycle_month": cycle_month,
                        "user_id": loser_id,
                        "winner_user_id": winner_user_id,
                        "your_urgency": b.get("urgency"),
                    },
                )
                regretted.append(loser_id)
            except Exception as e:  # noqa: BLE001
                log.warning(
                    "cycles.regret_send_failed",
                    user_id=loser_id,
                    error=str(e),
                )
        if regretted:
            await audit(
                actor="agent:bidding",
                action="bid.regret",
                resource_type="cycle",
                resource_id=cycle["id"],
                diff={
                    "cycle_month": cycle_month,
                    "winner_user_id": winner_user_id,
                    "regretted_user_ids": regretted,
                },
            )

    return {
        "ok": True,
        "cycle_month": cycle_month,
        "winner_user_id": winner_user_id,
        "winner_display_name": winner_member["users"]["display_name"],
        "winner_source": winner_source,
        "pot_cents": pool_cents,
        "amount_cents": winner_cents,
        "fee_cents": fee_cents,
        "fee_bps": fee_bps,
        "bunq_payment_id": bunq_payment_id,
        "bunq_error": bunq_error,
        "bunq_suspension": suspension_summary,
        "payout_status": (
            "suspended" if is_suspended
            else "committed" if bunq_payment_id
            else "pending"
        ),
        "rationale": rationale,
    }
