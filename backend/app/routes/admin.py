"""/admin/* — control-room dashboard for the entire platform.

Gated by `users.is_admin`. The first signed-in caller can self-bootstrap
when the table has zero admins (`POST /admin/bootstrap`); after that, only
existing admins can grant the bit.

Endpoints
---------
GET  /admin/overview            — top-line counters (groups, members, money flow)
GET  /admin/groups              — every circle with rolled-up state
GET  /admin/groups/{id}         — single-circle deep dive
GET  /admin/cycles?group_id=    — cycles filtered or all
GET  /admin/audit?limit=N       — agent + user tool calls
GET  /admin/agent-messages      — chat-style messages emitted by agents
GET  /admin/events?limit=N      — global event tape
"""
from __future__ import annotations

import math
import uuid as uuid_mod
from datetime import datetime, timedelta, timezone
from typing import Any
from uuid import UUID

from fastapi import APIRouter, HTTPException, Query
from pydantic import BaseModel, Field

from app.auth import AdminUserId, CurrentUserId
from app.bunq import get_bunq_client
from app.config import settings
from app.db import get_supabase
from app.ledger import create_group_accounts
from app.utils.logging import get_logger

log = get_logger(__name__)
router = APIRouter(prefix="/admin", tags=["admin"])


# ─────────────────────────────────────────────────────────────────────────────
# Admin role bootstrap + grant
# ─────────────────────────────────────────────────────────────────────────────
@router.post("/bootstrap")
async def bootstrap_admin(user_id: CurrentUserId) -> dict[str, Any]:
    """First-admin bootstrap. Only succeeds when the table has zero admins
    yet — promotes the caller. Once any admin exists, returns 409 and the
    caller must be granted by an existing admin via /admin/grant."""
    sb = get_supabase()
    existing = (
        sb.table("users")
        .select("id", count="exact")
        .eq("is_admin", True)
        .execute()
    )
    if (existing.count or 0) > 0:
        raise HTTPException(409, "an admin already exists — ask one to grant you")
    sb.table("users").update({"is_admin": True}).eq("id", str(user_id)).execute()
    sb.table("audit_log").insert(
        {
            "actor": f"user:{user_id}",
            "action": "admin.bootstrap",
            "resource_type": "user",
            "resource_id": str(user_id),
            "diff": {"is_admin": True, "reason": "first-admin bootstrap"},
        }
    ).execute()
    return {"user_id": str(user_id), "is_admin": True, "bootstrapped": True}


@router.post("/grant")
async def grant_admin(
    target_user_id: UUID, admin_id: AdminUserId
) -> dict[str, Any]:
    sb = get_supabase()
    sb.table("users").update({"is_admin": True}).eq(
        "id", str(target_user_id)
    ).execute()
    sb.table("audit_log").insert(
        {
            "actor": f"user:{admin_id}",
            "action": "admin.grant",
            "resource_type": "user",
            "resource_id": str(target_user_id),
            "diff": {"is_admin": True},
        }
    ).execute()
    return {"granted_to": str(target_user_id), "by": str(admin_id)}


# ─────────────────────────────────────────────────────────────────────────────
# Admin-created circles — circle templates the Matchmaker fills with members
# ─────────────────────────────────────────────────────────────────────────────
class CreateCircleBody(BaseModel):
    name: str = Field(min_length=1, max_length=64)
    contribution_amount_cents: int = Field(ge=100)
    cycle_count: int = Field(ge=2, le=24)
    currency: str = Field(default="EUR", min_length=3, max_length=3)
    grace_period_days: int = Field(default=3, ge=0, le=14)
    penalty_bps: int = Field(default=200, ge=0, le=2000)
    debit_day: int | None = Field(default=1, ge=1, le=28)
    starts_at: str | None = None  # ISO date "YYYY-MM-DD"
    accept_deadline_hours: int = Field(default=48, ge=1, le=720)
    min_trust_score: int = Field(default=50, ge=0, le=100)
    theme: str | None = None
    cultural_hint: str | None = None
    description: str | None = None
    payout_strategy: str = Field(default="rotation")
    max_members: int | None = None


@router.post("/circles")
async def create_admin_circle(
    body: CreateCircleBody, admin_id: AdminUserId
) -> dict[str, Any]:
    sb = get_supabase()
    group_id = uuid_mod.uuid4()
    invite_buffer = max(1, math.ceil(body.cycle_count * 0.2))
    accept_deadline = datetime.now(timezone.utc) + timedelta(
        hours=body.accept_deadline_hours
    )

    # TigerBeetle accounts for this circle.
    tb_ids = create_group_accounts(group_id, enforce_pool_invariant=True)

    # Platform admin's bunq account collects all contributions.
    platform_bunq_account_id: str | None = None
    try:
        client = get_bunq_client(settings.bunq_platform_label)
        await client.ensure_session()
        platform_bunq_account_id = str(await client.get_primary_account_id())
    except Exception:  # noqa: BLE001
        platform_bunq_account_id = None

    if body.payout_strategy not in ("rotation", "bidding", "hybrid"):
        raise HTTPException(400, "payout_strategy must be rotation|bidding|hybrid")

    sb.table("groups").insert(
        {
            "id": str(group_id),
            "name": body.name,
            "currency": body.currency.upper(),
            "contribution_amount_cents": body.contribution_amount_cents,
            "cycle_count": body.cycle_count,
            "grace_period_days": body.grace_period_days,
            "penalty_bps": body.penalty_bps,
            "tb_pool_account_id": tb_ids["pool"],
            "tb_gateway_account_id": tb_ids["gateway"],
            "tb_penalty_account_id": tb_ids["penalty"],
            "bunq_account_id": platform_bunq_account_id,
            "status": "recruiting",
            "invite_buffer": invite_buffer,
            "accept_deadline": accept_deadline.isoformat(),
            "starts_at": body.starts_at,
            "debit_day": body.debit_day,
            "min_trust_score": body.min_trust_score,
            "theme": body.theme,
            "cultural_hint": body.cultural_hint,
            "description": body.description,
            "payout_strategy": body.payout_strategy,
            "max_members": body.max_members or body.cycle_count,
            "created_by": str(admin_id),
            "created_by_agent": None,
        }
    ).execute()

    sb.table("audit_log").insert(
        {
            "actor": f"user:{admin_id}",
            "action": "admin.circle.create",
            "resource_type": "group",
            "resource_id": str(group_id),
            "diff": body.model_dump(mode="json"),
        }
    ).execute()

    sb.table("events").insert(
        {
            "group_id": str(group_id),
            "type": "admin.circle.opened",
            "payload": {
                "by": str(admin_id),
                "name": body.name,
                "min_trust_score": body.min_trust_score,
                "theme": body.theme,
            },
        }
    ).execute()

    return {
        "id": str(group_id),
        "name": body.name,
        "status": "recruiting",
        "min_trust_score": body.min_trust_score,
        "theme": body.theme,
        "bunq_account_id": platform_bunq_account_id,
    }


class UpdateCircleBody(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=64)
    description: str | None = None
    theme: str | None = None
    cultural_hint: str | None = None
    min_trust_score: int | None = Field(default=None, ge=0, le=100)
    max_members: int | None = Field(default=None, ge=2, le=24)
    debit_day: int | None = Field(default=None, ge=1, le=28)
    payout_strategy: str | None = None
    grace_period_days: int | None = Field(default=None, ge=0, le=14)
    penalty_bps: int | None = Field(default=None, ge=0, le=2000)
    starts_at: str | None = None
    accept_deadline: str | None = None
    # These two are restricted: only editable while the circle has no members
    # (and obviously no contributions). Refused otherwise.
    contribution_amount_cents: int | None = Field(default=None, ge=100)
    cycle_count: int | None = Field(default=None, ge=2, le=24)


@router.patch("/circles/{group_id}")
async def update_admin_circle(
    group_id: UUID, body: UpdateCircleBody, admin_id: AdminUserId
) -> dict[str, Any]:
    sb = get_supabase()
    g = (
        sb.table("groups").select("*").eq("id", str(group_id)).single().execute().data
    )
    if not g:
        raise HTTPException(404, "circle not found")
    if g.get("status") in ("active", "completed", "dissolved"):
        # Lock down hot fields once money is in flight.
        forbidden = {
            "contribution_amount_cents",
            "cycle_count",
            "max_members",
            "min_trust_score",
            "payout_strategy",
        }
        bad = [
            k
            for k, v in body.model_dump(exclude_none=True).items()
            if k in forbidden
        ]
        if bad:
            raise HTTPException(
                409,
                f"circle is {g['status']} — these fields are locked: {sorted(bad)}",
            )

    # Reshaping money math is dangerous once any member or contribution exists.
    members_count = int(
        (
            sb.table("members")
            .select("user_id", count="exact", head=True)
            .eq("group_id", str(group_id))
            .execute()
        ).count
        or 0
    )
    contribs_count = int(
        (
            sb.table("contributions")
            .select("id", count="exact", head=True)
            .eq("group_id", str(group_id))
            .execute()
        ).count
        or 0
    )

    if body.cycle_count is not None and members_count > 0:
        raise HTTPException(409, "cycle_count cannot change once members are present")
    if body.contribution_amount_cents is not None and contribs_count > 0:
        raise HTTPException(
            409, "contribution amount cannot change once contributions exist"
        )

    if body.payout_strategy is not None and body.payout_strategy not in (
        "rotation",
        "bidding",
        "hybrid",
    ):
        raise HTTPException(400, "payout_strategy must be rotation|bidding|hybrid")

    patch = body.model_dump(exclude_none=True)
    if not patch:
        return {"id": str(group_id), "updated": False, "fields": []}
    if "name" in patch:
        patch["name"] = patch["name"].strip()

    sb.table("groups").update(patch).eq("id", str(group_id)).execute()
    sb.table("audit_log").insert(
        {
            "actor": f"user:{admin_id}",
            "action": "admin.circle.update",
            "resource_type": "group",
            "resource_id": str(group_id),
            "diff": patch,
        }
    ).execute()
    sb.table("events").insert(
        {
            "group_id": str(group_id),
            "type": "admin.circle.updated",
            "payload": {"by": str(admin_id), "fields": sorted(patch.keys())},
        }
    ).execute()
    return {"id": str(group_id), "updated": True, "fields": sorted(patch.keys())}


@router.delete("/circles/{group_id}")
async def delete_admin_circle(group_id: UUID, admin_id: AdminUserId) -> dict[str, Any]:
    """Wipe an empty circle. Refuses to delete circles with any members or
    money movement — those need the proper dissolution flow."""
    sb = get_supabase()
    members = (
        sb.table("members")
        .select("user_id", count="exact", head=True)
        .eq("group_id", str(group_id))
        .execute()
    )
    if (members.count or 0) > 0:
        raise HTTPException(409, "circle has members — dissolve via lifecycle flow")
    contribs = (
        sb.table("contributions")
        .select("id", count="exact", head=True)
        .eq("group_id", str(group_id))
        .execute()
    )
    if (contribs.count or 0) > 0:
        raise HTTPException(409, "circle has contributions — cannot delete")
    sb.table("groups").delete().eq("id", str(group_id)).execute()
    sb.table("audit_log").insert(
        {
            "actor": f"user:{admin_id}",
            "action": "admin.circle.delete",
            "resource_type": "group",
            "resource_id": str(group_id),
            "diff": {},
        }
    ).execute()
    return {"deleted": str(group_id)}


@router.post("/revoke")
async def revoke_admin(
    target_user_id: UUID, admin_id: AdminUserId
) -> dict[str, Any]:
    if str(target_user_id) == str(admin_id):
        raise HTTPException(400, "you cannot revoke your own admin")
    sb = get_supabase()
    sb.table("users").update({"is_admin": False}).eq(
        "id", str(target_user_id)
    ).execute()
    sb.table("audit_log").insert(
        {
            "actor": f"user:{admin_id}",
            "action": "admin.revoke",
            "resource_type": "user",
            "resource_id": str(target_user_id),
            "diff": {"is_admin": False},
        }
    ).execute()
    return {"revoked_from": str(target_user_id), "by": str(admin_id)}


# ─────────────────────────────────────────────────────────────────────────────
# Overview
# ─────────────────────────────────────────────────────────────────────────────
@router.get("/overview")
async def overview(_: AdminUserId) -> dict[str, Any]:
    sb = get_supabase()

    def _count(table: str, **filters: Any) -> int:
        # head=True + count='exact' returns just the count without rows; works
        # for tables without an `id` column (e.g. members has a composite PK).
        q = sb.table(table).select("*", count="exact", head=True)
        for k, v in filters.items():
            q = q.eq(k, v)
        return int(q.execute().count or 0)

    groups_total = _count("groups")
    groups_active = _count("groups", status="active")
    groups_recruiting = _count("groups", status="recruiting")
    groups_awaiting = _count("groups", status="awaiting_accepts")
    groups_chartered = _count("groups", status="chartered")
    members_total = _count("members")
    cycles_total = _count("cycles")
    cycles_paid = _count("cycles", status="paid")
    cycles_fallback = _count("cycles", status="fallback")
    contributions_posted = _count("contributions", status="posted")
    payouts_committed = _count("payouts", status="committed")
    bids_total = _count("bids")
    audit_total = _count("audit_log")
    events_total = _count("events")

    # money totals
    contrib_amt = (
        sb.table("contributions")
        .select("amount_cents")
        .eq("status", "posted")
        .execute()
        .data
        or []
    )
    contrib_total_cents = sum(int(r.get("amount_cents") or 0) for r in contrib_amt)
    payout_amt = (
        sb.table("payouts")
        .select("amount_cents")
        .eq("status", "committed")
        .execute()
        .data
        or []
    )
    payout_total_cents = sum(int(r.get("amount_cents") or 0) for r in payout_amt)

    # agent activity rollup — group audit_log by actor (agent:<name> rows only)
    audit_rows = (
        sb.table("audit_log")
        .select("actor,action,created_at")
        .like("actor", "agent:%")
        .order("created_at", desc=True)
        .limit(2000)
        .execute()
        .data
        or []
    )
    by_agent: dict[str, dict[str, Any]] = {}
    for r in audit_rows:
        actor = r["actor"]
        agent = actor.split(":", 1)[1] if ":" in actor else actor
        slot = by_agent.setdefault(
            agent, {"agent": agent, "calls": 0, "fails": 0, "actions": {}}
        )
        slot["calls"] += 1
        action = (r.get("action") or "")
        if action.endswith(".error") or action.endswith(".failed"):
            slot["fails"] += 1
        head = action.split(".", 1)[0] or "?"
        slot["actions"][head] = slot["actions"].get(head, 0) + 1
    agents = sorted(by_agent.values(), key=lambda x: -x["calls"])

    return {
        "circles": {
            "total": groups_total,
            "active": groups_active,
            "recruiting": groups_recruiting,
            "awaiting_accepts": groups_awaiting,
            "chartered": groups_chartered,
        },
        "members_total": members_total,
        "cycles": {
            "total": cycles_total,
            "paid": cycles_paid,
            "fallback": cycles_fallback,
        },
        "money": {
            "contributions_posted": contributions_posted,
            "contributions_eur_cents": contrib_total_cents,
            "payouts_committed": payouts_committed,
            "payouts_eur_cents": payout_total_cents,
        },
        "bids_total": bids_total,
        "audit_total": audit_total,
        "events_total": events_total,
        "agents": agents,
    }


# ─────────────────────────────────────────────────────────────────────────────
# Groups
# ─────────────────────────────────────────────────────────────────────────────
@router.get("/groups")
async def list_groups(_: AdminUserId) -> list[dict[str, Any]]:
    sb = get_supabase()
    groups = (
        sb.table("groups")
        .select(
            "id,name,status,contribution_amount_cents,cycle_count,currency,"
            "created_at,starts_at,debit_day,invite_buffer,accept_deadline,"
            "min_trust_score,theme,cultural_hint,description,payout_strategy,"
            "max_members"
        )
        .order("created_at", desc=True)
        .execute()
        .data
        or []
    )
    if not groups:
        return []
    ids = [g["id"] for g in groups]

    # Pull child counts once and bucket in Python — keeps the request count flat.
    members = (
        sb.table("members")
        .select("group_id,status")
        .in_("group_id", ids)
        .execute()
        .data
        or []
    )
    contributions = (
        sb.table("contributions")
        .select("group_id,status")
        .in_("group_id", ids)
        .execute()
        .data
        or []
    )
    cycles = (
        sb.table("cycles")
        .select("group_id,status")
        .in_("group_id", ids)
        .execute()
        .data
        or []
    )
    payouts = (
        sb.table("payouts")
        .select("group_id,status,amount_cents")
        .in_("group_id", ids)
        .execute()
        .data
        or []
    )

    counts: dict[str, dict[str, Any]] = {
        gid: {
            "members_total": 0,
            "members_accepted": 0,
            "members_active": 0,
            "contributions_posted": 0,
            "cycles_paid": 0,
            "cycles_open": 0,
            "payouts_committed_cents": 0,
        }
        for gid in ids
    }
    for r in members:
        c = counts[r["group_id"]]
        c["members_total"] += 1
        if r["status"] == "accepted":
            c["members_accepted"] += 1
        elif r["status"] in ("active", "received"):
            c["members_active"] += 1
    for r in contributions:
        if r["status"] == "posted":
            counts[r["group_id"]]["contributions_posted"] += 1
    for r in cycles:
        if r["status"] in ("paid", "fallback"):
            counts[r["group_id"]]["cycles_paid"] += 1
        elif r["status"] in ("scheduled", "contribution_window", "bid_window", "resolving"):
            counts[r["group_id"]]["cycles_open"] += 1
    for r in payouts:
        if r["status"] == "committed":
            counts[r["group_id"]]["payouts_committed_cents"] += int(r.get("amount_cents") or 0)

    return [{**g, **counts[g["id"]]} for g in groups]


@router.get("/groups/{group_id}")
async def group_detail(group_id: UUID, _: AdminUserId) -> dict[str, Any]:
    sb = get_supabase()
    gid = str(group_id)
    g = sb.table("groups").select("*").eq("id", gid).single().execute().data
    if not g:
        raise HTTPException(404, "group not found")
    members = (
        sb.table("members")
        .select(
            "user_id,role,status,payout_cycle,received_at,"
            "accepted_charter_at,joined_at,invited_at,mandate_id,debit_day"
        )
        .eq("group_id", gid)
        .execute()
        .data
        or []
    )
    # join display_name onto members for the dashboard (RLS-bypassed)
    if members:
        uids = [m["user_id"] for m in members]
        users = (
            sb.table("users")
            .select("id,display_name,trust_score,bunq_label")
            .in_("id", uids)
            .execute()
            .data
            or []
        )
        by_id = {u["id"]: u for u in users}
        for m in members:
            u = by_id.get(m["user_id"]) or {}
            m["display_name"] = u.get("display_name")
            m["trust_score"] = u.get("trust_score")
            m["bunq_label"] = u.get("bunq_label")

    cycles = (
        sb.table("cycles")
        .select("*")
        .eq("group_id", gid)
        .order("cycle_month")
        .execute()
        .data
        or []
    )
    contributions = (
        sb.table("contributions")
        .select("user_id,cycle_month,amount_cents,status,created_at")
        .eq("group_id", gid)
        .order("created_at", desc=True)
        .execute()
        .data
        or []
    )
    payouts = (
        sb.table("payouts")
        .select(
            "recipient_user_id,cycle_month,amount_cents,status,"
            "bunq_payment_id,committed_at,created_at"
        )
        .eq("group_id", gid)
        .order("created_at", desc=True)
        .execute()
        .data
        or []
    )
    bids = (
        sb.table("bids")
        .select("cycle_id,user_id,urgency,reason,reason_score,withdrawn_at,created_at")
        .order("created_at", desc=True)
        .execute()
        .data
        or []
    )
    cycle_ids = {c["id"] for c in cycles}
    bids = [b for b in bids if b["cycle_id"] in cycle_ids]
    events = (
        sb.table("events")
        .select("type,payload,created_at")
        .eq("group_id", gid)
        .order("created_at", desc=True)
        .limit(200)
        .execute()
        .data
        or []
    )
    audit = (
        sb.table("audit_log")
        .select("actor,action,resource_type,resource_id,diff,created_at")
        .or_(f"resource_id.eq.{gid},diff->>group_id.eq.{gid}")
        .order("created_at", desc=True)
        .limit(200)
        .execute()
        .data
        or []
    )

    # Enrich each payout with the latest bunq-leg event for its cycle so
    # the UI can render "bunq holding (NEW_COUNTERPARTY · arrives MM/DD)"
    # without re-walking the events array client-side.
    bunq_event_types = {"payout.bunq_suspended", "payout.committed", "payout.ledger_only"}
    for p in payouts:
        match: dict[str, Any] | None = None
        for ev in events:  # already ordered DESC, most recent first
            if ev.get("type") not in bunq_event_types:
                continue
            payload = ev.get("payload") or {}
            if payload.get("cycle_month") != p.get("cycle_month"):
                continue
            match = payload
            break
        if match:
            p["bunq_suspension"] = match.get("bunq_suspension")
            p["bunq_event_type"] = (
                "payout.bunq_suspended"
                if match.get("bunq_suspension")
                and (match["bunq_suspension"].get("status") or "").upper() == "PENDING"
                else (
                    "payout.committed" if p.get("bunq_payment_id") else "payout.ledger_only"
                )
            )

    return {
        "group": g,
        "members": members,
        "cycles": cycles,
        "contributions": contributions,
        "payouts": payouts,
        "bids": bids,
        "events": events,
        "audit": audit,
    }


# ─────────────────────────────────────────────────────────────────────────────
# Audit log + agent messages + global events
# ─────────────────────────────────────────────────────────────────────────────
@router.get("/audit")
async def audit(
    _: AdminUserId,
    limit: int = Query(200, ge=1, le=1000),
    actor_kind: str | None = Query(None, description="'agent' or 'user'"),
) -> list[dict[str, Any]]:
    sb = get_supabase()
    q = (
        sb.table("audit_log")
        .select("id,actor,action,resource_type,resource_id,diff,created_at")
        .order("created_at", desc=True)
        .limit(limit)
    )
    if actor_kind == "agent":
        q = q.like("actor", "agent:%")
    elif actor_kind == "user":
        q = q.like("actor", "user:%")
    return q.execute().data or []


@router.get("/agent-messages")
async def agent_messages(
    _: AdminUserId,
    limit: int = Query(200, ge=1, le=1000),
) -> list[dict[str, Any]]:
    sb = get_supabase()
    return (
        sb.table("messages")
        .select("id,group_id,agent_name,sender_user_id,text,created_at")
        .not_.is_("agent_name", "null")
        .order("created_at", desc=True)
        .limit(limit)
        .execute()
        .data
        or []
    )


@router.get("/events")
async def events(
    _: AdminUserId,
    limit: int = Query(200, ge=1, le=1000),
    type_prefix: str | None = Query(None, description="filter type LIKE prefix.%"),
) -> list[dict[str, Any]]:
    sb = get_supabase()
    q = (
        sb.table("events")
        .select("id,group_id,type,payload,created_at")
        .order("created_at", desc=True)
        .limit(limit)
    )
    if type_prefix:
        q = q.like("type", f"{type_prefix}%")
    return q.execute().data or []


@router.get("/waitlist")
async def waitlist(_: AdminUserId) -> list[dict[str, Any]]:
    """Every user the Matchmaker has parked on the waitlist + their stated
    preferences and what circles they're currently a candidate for.

    Also surfaces users invited to a recruiting/awaiting_accepts pod who
    haven't accepted yet — they're in flight, not truly idle, but the admin
    needs to see them so they don't disappear after the matchmaker runs."""
    sb = get_supabase()
    waiters = (
        sb.table("users")
        .select(
            "id,display_name,bunq_label,trust_score,goal,match_preferences,"
            "waitlist_since,waitlist_status,is_admin"
        )
        .eq("waitlist_status", "waiting")
        .order("waitlist_since")
        .execute()
        .data
        or []
    )
    waiter_ids = {w["id"] for w in waiters}

    # Users with an outstanding invite (status='invited') in a non-finalised
    # group. Pull the joined group so we can render the badge with name +
    # accept deadline.
    pending_rows = (
        sb.table("members")
        .select(
            "user_id,status,invited_at,"
            "groups!inner(id,name,status,accept_deadline,"
            "contribution_amount_cents,cycle_count,min_trust_score,"
            "max_members,description)"
        )
        .eq("status", "invited")
        .in_("groups.status", ["recruiting", "awaiting_accepts"])
        .execute()
        .data
        or []
    )
    pending_by_user: dict[str, dict[str, Any]] = {}
    for r in pending_rows:
        if not r.get("groups"):
            continue
        pending_by_user[r["user_id"]] = {
            "invited_at": r.get("invited_at"),
            "group": r["groups"],
        }

    # Hydrate any pending-invite users that weren't already in the waiters
    # list (waitlist_status got flipped to 'matched' the moment they were
    # invited, so they fell off the 'waiting' query above).
    extra_user_ids = [uid for uid in pending_by_user.keys() if uid not in waiter_ids]
    if extra_user_ids:
        extras = (
            sb.table("users")
            .select(
                "id,display_name,bunq_label,trust_score,goal,match_preferences,"
                "waitlist_since,waitlist_status,is_admin"
            )
            .in_("id", extra_user_ids)
            .execute()
            .data
            or []
        )
        waiters.extend(extras)

    if not waiters:
        return []

    # Pre-load every recruiting/active group so we can match preferences
    # without N+1 queries.
    circles = (
        sb.table("groups")
        .select(
            "id,name,status,theme,cultural_hint,contribution_amount_cents,"
            "cycle_count,min_trust_score,max_members,description"
        )
        .in_("status", ["recruiting", "awaiting_accepts", "active"])
        .execute()
        .data
        or []
    )
    members = (
        sb.table("members")
        .select("group_id,user_id")
        .in_("group_id", [c["id"] for c in circles] or ["00000000-0000-0000-0000-000000000000"])
        .execute()
        .data
        or []
    )
    member_count: dict[str, int] = {}
    for m in members:
        member_count[m["group_id"]] = member_count.get(m["group_id"], 0) + 1

    out: list[dict[str, Any]] = []
    for u in waiters:
        prefs = u.get("match_preferences") or {}
        target_amount = prefs.get("contribution_amount_cents")
        target_cycles = prefs.get("cycle_count")
        cand_trust = int(u.get("trust_score") or 50)

        candidates: list[dict[str, Any]] = []
        for c in circles:
            cap = c.get("max_members") or c["cycle_count"]
            if member_count.get(c["id"], 0) >= cap:
                continue
            if cand_trust < int(c.get("min_trust_score") or 0):
                continue
            # Hard cycle_count + amount band match (same rules as Matchmaker).
            if target_cycles and int(target_cycles) != c["cycle_count"]:
                continue
            if target_amount:
                lo = int(target_amount) * 0.85
                hi = int(target_amount) * 1.15
                if not (lo <= c["contribution_amount_cents"] <= hi):
                    continue
            score = 1
            if target_amount and abs(int(target_amount) - c["contribution_amount_cents"]) < 2500:
                score += 2
            if (prefs.get("cultural_hint") or "") and c.get("cultural_hint") and \
                    prefs["cultural_hint"].lower() in (c["cultural_hint"] or "").lower():
                score += 2
            candidates.append({**c, "fit_score": score})
        candidates.sort(key=lambda x: -x["fit_score"])

        pending = pending_by_user.get(u["id"])
        out.append(
            {
                **u,
                "state": "invited_pending" if pending else "waiting",
                "pending_invite": pending,
                "candidate_circles": [] if pending else candidates[:5],
            }
        )
    # Sort: truly waiting first (oldest first), then pending invites.
    out.sort(
        key=lambda r: (
            0 if r["state"] == "waiting" else 1,
            r.get("waitlist_since") or "",
        )
    )
    return out


@router.get("/cycles")
async def cycles(
    _: AdminUserId,
    group_id: UUID | None = Query(None),
    limit: int = Query(200, ge=1, le=1000),
) -> list[dict[str, Any]]:
    sb = get_supabase()
    q = (
        sb.table("cycles")
        .select("*")
        .order("created_at", desc=True)
        .limit(limit)
    )
    if group_id:
        q = q.eq("group_id", str(group_id))
    return q.execute().data or []
