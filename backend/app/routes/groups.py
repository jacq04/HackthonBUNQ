"""Group lifecycle routes.

POST   /groups              Create a new group
GET    /groups              List current user's groups
GET    /groups/{id}         Group detail
POST   /groups/{id}/invite  Generate a signed invite token for QR
POST   /groups/join         Join a group via signed invite token
"""
from __future__ import annotations

import uuid
from typing import Any

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from app.auth import CurrentUserId
from app.bunq import get_bunq_client
from app.config import settings
from app.db import get_supabase
from app.ledger import create_group_accounts
from app.ledger.tb_client import AccountCode, account_id_for, create_member_accounts
from app.utils.invites import make_invite, verify_invite
from app.utils.logging import get_logger

log = get_logger(__name__)
router = APIRouter(prefix="/groups", tags=["groups"])


class CreateGroupBody(BaseModel):
    name: str = Field(min_length=1, max_length=100)
    contribution_amount_cents: int = Field(ge=100)
    cycle_count: int = Field(ge=2, le=24)
    currency: str = "EUR"
    grace_period_days: int = 3
    penalty_bps: int = 200


class CreateGroupResponse(BaseModel):
    id: uuid.UUID
    name: str
    tb_pool_account_id: str
    tb_gateway_account_id: str
    tb_penalty_account_id: str
    bunq_account_id: str | None


@router.post("", response_model=CreateGroupResponse)
async def create_group(body: CreateGroupBody, user_id: CurrentUserId) -> CreateGroupResponse:
    # Circles are formed by the Matchmaker agent (or the platform), not by users
    # directly. Keep the handler so backend code and tests can still call it,
    # but reject user-origin traffic. Bypassed in development for easier demos.
    if settings.is_production:
        raise HTTPException(
            status_code=403,
            detail="Circles are formed by the Matchmaker — use POST /matchmaker/find-circle",
        )
    group_id = uuid.uuid4()

    # 1. TigerBeetle — create pool + gateway + penalty accounts.
    tb_ids = create_group_accounts(group_id, enforce_pool_invariant=True)

    # 2. bunq — create a sub-account for the group (best-effort; tolerate failure in dev).
    bunq_account_id: str | None = None
    try:
        bunq = get_bunq_client()
        resp = await bunq.create_joint_account(description=f"Kitty {body.name}")
        bunq_account_id = str(resp.get("id") or "") or None
    except Exception as e:  # noqa: BLE001
        log.warning("groups.bunq_subaccount_failed", error=str(e))

    # 3. Postgres — persist the group row.
    sb = get_supabase()
    sb.table("groups").insert(
        {
            "id": str(group_id),
            "name": body.name,
            "currency": body.currency,
            "contribution_amount_cents": body.contribution_amount_cents,
            "cycle_count": body.cycle_count,
            "grace_period_days": body.grace_period_days,
            "penalty_bps": body.penalty_bps,
            "bunq_account_id": bunq_account_id,
            "tb_pool_account_id": tb_ids["pool"],
            "tb_gateway_account_id": tb_ids["gateway"],
            "tb_penalty_account_id": tb_ids["penalty"],
            "status": "charter",
            "created_by": str(user_id),
        }
    ).execute()

    # 4. Add the creator as the first member (admin).
    member_ids = create_member_accounts(group_id, user_id)
    sb.table("members").insert(
        {
            "group_id": str(group_id),
            "user_id": str(user_id),
            "role": "admin",
            "status": "active",
            "tb_contrib_account_id": member_ids["contrib"],
            "tb_received_account_id": member_ids["received"],
        }
    ).execute()

    return CreateGroupResponse(
        id=group_id,
        name=body.name,
        tb_pool_account_id=str(tb_ids["pool"]),
        tb_gateway_account_id=str(tb_ids["gateway"]),
        tb_penalty_account_id=str(tb_ids["penalty"]),
        bunq_account_id=bunq_account_id,
    )


@router.get("")
async def list_my_groups(user_id: CurrentUserId) -> list[dict[str, Any]]:
    """Pods the signed-in user has actually joined (accepted+) — invitations
    they haven't responded to live behind /me/invitations instead, so the
    wallet doesn't conflate "pending invite" with "joined pod"."""
    sb = get_supabase()
    r = (
        sb.table("members")
        .select("group_id,status,groups(*)")
        .eq("user_id", str(user_id))
        .in_("status", ["accepted", "active", "received", "exited_clean"])
        .execute()
    )
    return [row["groups"] for row in (r.data or []) if row.get("groups")]


@router.get("/{group_id}")
async def get_group(group_id: uuid.UUID, user_id: CurrentUserId) -> dict[str, Any]:
    sb = get_supabase()
    g = sb.table("groups").select("*").eq("id", str(group_id)).single().execute()
    if not g.data:
        raise HTTPException(status_code=404, detail="not found")
    m = sb.table("members").select("*,users(display_name,language)").eq("group_id", str(group_id)).execute()
    c = (
        sb.table("charters")
        .select("*")
        .eq("group_id", str(group_id))
        .order("version", desc=True)
        .limit(1)
        .execute()
    )
    return {"group": g.data, "members": m.data or [], "charter": (c.data[0] if c.data else None)}


class InviteResponse(BaseModel):
    token: str
    deep_link: str


@router.post("/{group_id}/invite", response_model=InviteResponse)
async def create_invite(group_id: uuid.UUID, user_id: CurrentUserId) -> InviteResponse:
    # Only group admins can invite — trust Postgres RLS to guard reads; we do a soft check here.
    sb = get_supabase()
    r = (
        sb.table("members")
        .select("role")
        .eq("group_id", str(group_id))
        .eq("user_id", str(user_id))
        .single()
        .execute()
    )
    if not r.data or r.data.get("role") != "admin":
        raise HTTPException(status_code=403, detail="admins only")

    token = make_invite(group_id)
    return InviteResponse(token=token, deep_link=f"kitty://join?code={token}")


class JoinBody(BaseModel):
    code: str


@router.post("/join")
async def join_via_invite(body: JoinBody, user_id: CurrentUserId) -> dict[str, Any]:
    try:
        group_id = verify_invite(body.code)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e)) from e

    sb = get_supabase()
    # TB member accounts (idempotent for re-joins).
    member_ids = create_member_accounts(group_id, user_id)

    sb.table("members").upsert(
        {
            "group_id": str(group_id),
            "user_id": str(user_id),
            "role": "member",
            "status": "active",
            "tb_contrib_account_id": member_ids["contrib"],
            "tb_received_account_id": member_ids["received"],
        }
    ).execute()

    return {"ok": True, "group_id": str(group_id)}
