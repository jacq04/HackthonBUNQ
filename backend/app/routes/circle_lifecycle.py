"""Circle lifecycle transitions invoked by the platform / admin.

    POST /groups/{id}/start   chartered → active; seeds public.cycles rows

The Matchmaker / accept flow handles everything up to `chartered`. Once a
circle is chartered, an admin (or a scheduled start-date trigger) calls /start
to kick the first cycle off. Slot order is taken from Payout Optimizer if
already run, else a stable 1..N order by acceptance time.
"""
from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from app.agents.tools import audit, emit_event
from app.auth import CurrentUserId
from app.db import get_supabase
from app.utils.logging import get_logger

log = get_logger(__name__)
router = APIRouter(prefix="/groups/{group_id}", tags=["lifecycle"])


class StartBody(BaseModel):
    # Optional overrides so demo scripts can deterministically seed short windows.
    contribution_window_hours: int = Field(default=72, ge=1, le=720)
    bid_window_hours: int = Field(default=24, ge=1, le=168)
    cycle_stride_days: int = Field(default=30, ge=1, le=60)


class StartResponse(BaseModel):
    group_id: uuid.UUID
    status: str
    cycles_created: int
    first_bid_closes_at: str | None


@router.post("/start", response_model=StartResponse)
async def start_circle(
    group_id: uuid.UUID, body: StartBody, user_id: CurrentUserId
) -> StartResponse:
    sb = get_supabase()
    group = sb.table("groups").select("*").eq("id", str(group_id)).single().execute().data
    if not group:
        raise HTTPException(status_code=404, detail="group not found")
    if group["status"] != "chartered":
        raise HTTPException(
            status_code=409,
            detail=f"group is {group['status']}, expected 'chartered'",
        )

    # Admin-only in practice; for demos any member can trigger.
    me = (
        sb.table("members")
        .select("role,status")
        .eq("group_id", str(group_id))
        .eq("user_id", str(user_id))
        .maybe_single()
        .execute()
    )
    if not me or not me.data:
        raise HTTPException(status_code=403, detail="not a member")

    cycle_count = int(group["cycle_count"])

    # Ensure every accepted member has a payout_cycle (1..N) assigned. Prefer
    # an existing assignment (Payout Optimizer may have filled it in); fall
    # back to acceptance order.
    members = (
        sb.table("members")
        .select("user_id,payout_cycle,accepted_charter_at")
        .eq("group_id", str(group_id))
        .eq("status", "accepted")
        .order("accepted_charter_at")
        .execute()
        .data
        or []
    )
    if len(members) != cycle_count:
        raise HTTPException(
            status_code=409,
            detail=f"need exactly {cycle_count} accepted members (have {len(members)})",
        )

    taken = {m["payout_cycle"] for m in members if m.get("payout_cycle")}
    next_slot = (i for i in range(1, cycle_count + 1) if i not in taken)
    for m in members:
        slot = m.get("payout_cycle")
        if not slot:
            slot = next(next_slot)
            sb.table("members").update({"payout_cycle": slot}).eq(
                "group_id", str(group_id)
            ).eq("user_id", m["user_id"]).execute()
        # Promote accepted → active (circle going live).
        sb.table("members").update({"status": "active"}).eq(
            "group_id", str(group_id)
        ).eq("user_id", m["user_id"]).execute()

    # Seed one `cycles` row per month.
    now = datetime.now(timezone.utc)
    first_bid_closes_at: str | None = None
    for cycle_month in range(1, cycle_count + 1):
        start_of_cycle = now + timedelta(days=(cycle_month - 1) * body.cycle_stride_days)
        contrib_opens = start_of_cycle
        bid_opens = start_of_cycle + timedelta(hours=body.contribution_window_hours)
        bid_closes = bid_opens + timedelta(hours=body.bid_window_hours)
        payout_at = bid_closes + timedelta(hours=1)
        status = "contribution_window" if cycle_month == 1 else "scheduled"
        if cycle_month == 1:
            first_bid_closes_at = bid_closes.isoformat()
        sb.table("cycles").insert(
            {
                "group_id": str(group_id),
                "cycle_month": cycle_month,
                "contribution_opens_at": contrib_opens.isoformat(),
                "bid_opens_at": bid_opens.isoformat(),
                "bid_closes_at": bid_closes.isoformat(),
                "payout_at": payout_at.isoformat(),
                "status": status,
            }
        ).execute()

    sb.table("groups").update(
        {
            "status": "active",
            "starts_at": now.date().isoformat(),
        }
    ).eq("id", str(group_id)).execute()

    await emit_event(
        group_id,
        type="group.active",
        payload={"cycles_created": cycle_count, "starts_at": now.date().isoformat()},
    )
    await audit(
        actor=f"user:{user_id}",
        action="group.start",
        resource_type="group",
        resource_id=str(group_id),
        diff={"cycles_created": cycle_count},
    )

    return StartResponse(
        group_id=group_id,
        status="active",
        cycles_created=cycle_count,
        first_bid_closes_at=first_bid_closes_at,
    )
