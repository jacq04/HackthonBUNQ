"""Add / remove members of a group.

Authenticated endpoints; admin-only for mutations.

POST  /groups/{id}/members/add-bunq    body: {label}       add a bunq sandbox user
GET   /groups/{id}/members/candidates                      list bunq users NOT yet in the group
"""
from __future__ import annotations

import uuid
from typing import Any

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from app.auth import CurrentUserId
from app.db import get_supabase
from app.ledger.tb_client import create_member_accounts
from app.routes.auth_bunq import _bunq_profile, list_bunq_users
from app.utils.logging import get_logger

log = get_logger(__name__)
router = APIRouter(prefix="/groups/{group_id}/members", tags=["members"])


class AddBunqMemberRequest(BaseModel):
    label: str


class AddBunqMemberResponse(BaseModel):
    user_id: uuid.UUID
    display_name: str
    bunq_label: str
    primary_iban: str | None
    payout_cycle: int | None


def _assert_admin(sb: Any, group_id: uuid.UUID, user_id: uuid.UUID) -> None:
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


@router.get("/candidates")
async def list_candidates(group_id: uuid.UUID, user_id: CurrentUserId) -> list[dict]:
    """Every bunq sandbox user on this host MINUS the users already in this group."""
    sb = get_supabase()
    current = sb.table("members").select("users!inner(bunq_label)").eq("group_id", str(group_id)).execute()
    already = {row["users"]["bunq_label"] for row in (current.data or []) if row.get("users", {}).get("bunq_label")}

    all_users = await list_bunq_users()
    return [u.model_dump() for u in all_users if u.label not in already]


@router.post("/add-bunq", response_model=AddBunqMemberResponse)
async def add_bunq_member(
    group_id: uuid.UUID, body: AddBunqMemberRequest, user_id: CurrentUserId
) -> AddBunqMemberResponse:
    sb = get_supabase()
    _assert_admin(sb, group_id, user_id)

    # 1. Pull the authoritative bunq profile.
    profile = await _bunq_profile(body.label)
    email = f"{body.label}@kitty.demo"

    # 2. Find-or-create the Supabase auth user.
    existing_auth = sb.auth.admin.list_users() or []
    auth_user = next((u for u in existing_auth if getattr(u, "email", None) == email), None)
    if not auth_user:
        auth_user = sb.auth.admin.create_user(
            {
                "email": email,
                "email_confirm": True,
                "user_metadata": {
                    "display_name": profile["display_name"],
                    "bunq_user_id": profile["bunq_user_id"],
                    "bunq_label": body.label,
                },
            }
        ).user
    new_user_id = uuid.UUID(auth_user.id)

    # 3. Upsert the public profile (display name always authoritative from bunq).
    sb.table("users").upsert(
        {
            "id": str(new_user_id),
            "display_name": profile["display_name"],
            "bunq_user_id": str(profile["bunq_user_id"]) if profile["bunq_user_id"] else None,
            "bunq_label": body.label,
        },
        on_conflict="id",
    ).execute()

    # 4. Reject double-adds.
    dup = (
        sb.table("members")
        .select("user_id")
        .eq("group_id", str(group_id))
        .eq("user_id", str(new_user_id))
        .execute()
    )
    if dup.data:
        raise HTTPException(status_code=409, detail=f"{profile['display_name']} is already a member")

    # 5. Per-member TigerBeetle accounts.
    tb_member = create_member_accounts(group_id, new_user_id)

    # 6. Pick the next open payout cycle (fall back to null if the group is full).
    group = sb.table("groups").select("cycle_count").eq("id", str(group_id)).single().execute()
    cycle_count = int((group.data or {}).get("cycle_count") or 0)
    taken = {
        row["payout_cycle"]
        for row in (
            sb.table("members")
            .select("payout_cycle")
            .eq("group_id", str(group_id))
            .execute()
            .data
            or []
        )
        if row.get("payout_cycle")
    }
    next_cycle = next((c for c in range(1, cycle_count + 1) if c not in taken), None)

    # 7. Insert the membership.
    sb.table("members").insert(
        {
            "group_id": str(group_id),
            "user_id": str(new_user_id),
            "role": "member",
            "status": "active",
            "payout_cycle": next_cycle,
            "tb_contrib_account_id": tb_member["contrib"],
            "tb_received_account_id": tb_member["received"],
        }
    ).execute()

    log.info(
        "members.add_bunq",
        group_id=str(group_id),
        added_user_id=str(new_user_id),
        bunq_label=body.label,
        cycle=next_cycle,
    )

    return AddBunqMemberResponse(
        user_id=new_user_id,
        display_name=profile["display_name"],
        bunq_label=body.label,
        primary_iban=profile["primary_iban"],
        payout_cycle=next_cycle,
    )
