"""Invitation accept / decline + charter transition.

    POST /groups/{id}/invites/respond   body={decision, debit_day?, monthly_cap_cents?, terms_version?}

On accept:
  1. Validate the user is still 'invited' in this group.
  2. Insert public.mandates row via bunq.create_autoflow (sandbox-stubbed).
  3. Flip members.status → 'accepted', store mandate_id + debit_day +
     accepted_charter_at.
  4. If count(accepted) >= cycle_count, transition groups.status → 'chartered'
     and downgrade any excess 'invited' rows to 'exited_clean' (buffer not
     needed).

On decline: flip members.status → 'declined'. If the remaining invited+accepted
pool drops below cycle_count, the Matchmaker's timeout tick will try to top up.
"""
from __future__ import annotations

import uuid
from datetime import datetime, timezone
from typing import Any, Literal

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from app.agents.tools import audit, emit_event
from app.auth import CurrentUserId
from app.bunq import get_bunq_client
from app.db import get_supabase
from app.utils.logging import get_logger

log = get_logger(__name__)
router = APIRouter(prefix="/groups/{group_id}/invites", tags=["invites"])


class RespondBody(BaseModel):
    decision: Literal["accept", "decline"]
    debit_day: int | None = Field(default=None, ge=1, le=28)
    monthly_cap_cents: int | None = Field(default=None, ge=100)
    terms_version: int = Field(default=1, ge=1)


class RespondResponse(BaseModel):
    decision: str
    member_status: str
    group_status: str
    mandate_id: str | None = None
    bunq_mandate_id: str | None = None
    accepted_count: int
    target_count: int


@router.post("/respond", response_model=RespondResponse)
async def respond(
    group_id: uuid.UUID, body: RespondBody, user_id: CurrentUserId
) -> RespondResponse:
    sb = get_supabase()

    # Fetch the invite + group + charter version.
    member_row = (
        sb.table("members")
        .select("status, user_id, users!inner(bunq_label)")
        .eq("group_id", str(group_id))
        .eq("user_id", str(user_id))
        .maybe_single()
        .execute()
    )
    if not member_row or not member_row.data:
        raise HTTPException(status_code=404, detail="no invite for this user in this group")
    m = member_row.data
    if m["status"] not in ("invited",):
        raise HTTPException(
            status_code=409, detail=f"cannot respond from status={m['status']}"
        )

    group_row = (
        sb.table("groups").select("*").eq("id", str(group_id)).single().execute().data
    )
    if group_row["status"] != "awaiting_accepts":
        raise HTTPException(
            status_code=409, detail=f"group is {group_row['status']}, not awaiting_accepts"
        )

    # ── Decline path ──────────────────────────────────────────────────────
    if body.decision == "decline":
        sb.table("members").update(
            {"status": "declined", "declined_at": datetime.now(timezone.utc).isoformat()}
        ).eq("group_id", str(group_id)).eq("user_id", str(user_id)).execute()
        await emit_event(
            group_id, type="member.declined", payload={"user_id": str(user_id)}
        )
        await audit(
            actor=f"user:{user_id}",
            action="invite.decline",
            resource_type="group",
            resource_id=str(group_id),
            diff={"user_id": str(user_id)},
        )
        counts = _counts(sb, group_id)
        return RespondResponse(
            decision="decline",
            member_status="declined",
            group_status=group_row["status"],
            accepted_count=counts["accepted"],
            target_count=int(group_row["cycle_count"]),
        )

    # ── Accept path ───────────────────────────────────────────────────────
    debit_day = body.debit_day or group_row.get("debit_day") or 1
    monthly_cap = body.monthly_cap_cents or int(
        round(int(group_row["contribution_amount_cents"]) * 1.10)
    )

    # Provision a SEPA-style mandate via bunq (sandbox stub for now).
    bunq_label = m["users"]["bunq_label"]
    bunq_mandate_id: str | None = None
    iban: str | None = None
    if bunq_label:
        try:
            client = get_bunq_client(bunq_label)
            await client.ensure_session()
            acct_id = await client.get_primary_account_id()
            # IBAN for the record (reads first alias; tolerant of failure).
            try:
                accts = await client.list_monetary_accounts()
                for a in accts:
                    if a.get("id") == acct_id:
                        for alias in a.get("alias") or []:
                            if alias.get("type") == "IBAN":
                                iban = alias.get("value")
                                break
                        break
            except Exception:  # noqa: BLE001
                pass
            autoflow = await client.create_autoflow(
                from_account_id=acct_id,
                description=f"Kitty · {group_row['name']}",
                monthly_cap_cents=monthly_cap,
                debit_day=debit_day,
            )
            bunq_mandate_id = autoflow.get("id")
        except Exception as e:  # noqa: BLE001
            log.warning("invites.bunq_autoflow_failed", error=str(e), label=bunq_label)

    mandate_row_id = str(uuid.uuid4())
    sb.table("mandates").insert(
        {
            "id": mandate_row_id,
            "user_id": str(user_id),
            "group_id": str(group_id),
            "bunq_mandate_id": bunq_mandate_id,
            "iban": iban,
            "debit_day": debit_day,
            "monthly_cap_cents": monthly_cap,
            "terms_version": body.terms_version,
        }
    ).execute()

    sb.table("members").update(
        {
            "status": "accepted",
            "accepted_charter_at": datetime.now(timezone.utc).isoformat(),
            "debit_day": debit_day,
            "mandate_id": mandate_row_id,
        }
    ).eq("group_id", str(group_id)).eq("user_id", str(user_id)).execute()

    await emit_event(
        group_id,
        type="member.accepted",
        payload={
            "user_id": str(user_id),
            "mandate_id": mandate_row_id,
            "debit_day": debit_day,
        },
    )
    await audit(
        actor=f"user:{user_id}",
        action="invite.accept",
        resource_type="group",
        resource_id=str(group_id),
        diff={"mandate_id": mandate_row_id, "debit_day": debit_day, "monthly_cap_cents": monthly_cap},
    )

    # Did we just cross the chartered threshold?
    counts = _counts(sb, group_id)
    new_group_status = group_row["status"]
    if counts["accepted"] >= int(group_row["cycle_count"]):
        _transition_to_chartered(sb, group_id, group_row["cycle_count"])
        new_group_status = "chartered"

    return RespondResponse(
        decision="accept",
        member_status="accepted",
        group_status=new_group_status,
        mandate_id=mandate_row_id,
        bunq_mandate_id=bunq_mandate_id,
        accepted_count=counts["accepted"],
        target_count=int(group_row["cycle_count"]),
    )


def _counts(sb: Any, group_id: uuid.UUID) -> dict[str, int]:
    r = (
        sb.table("members")
        .select("status")
        .eq("group_id", str(group_id))
        .execute()
    )
    rows = r.data or []
    out = {"invited": 0, "accepted": 0, "declined": 0, "active": 0, "total": len(rows)}
    for row in rows:
        out[row["status"]] = out.get(row["status"], 0) + 1
    return out


def _transition_to_chartered(sb: Any, group_id: uuid.UUID, cycle_count: int) -> None:
    """Flip the group to 'chartered' and retire any still-open invites past the
    required headcount so the buffer doesn't create ghost members."""
    sb.table("groups").update({"status": "chartered"}).eq(
        "id", str(group_id)
    ).execute()

    excess = (
        sb.table("members")
        .select("user_id,status")
        .eq("group_id", str(group_id))
        .in_("status", ["invited"])
        .execute()
    )
    if excess.data:
        sb.table("members").update({"status": "exited_clean"}).eq(
            "group_id", str(group_id)
        ).in_("status", ["invited"]).execute()
        log.info(
            "invites.retired_buffer",
            group_id=str(group_id),
            count=len(excess.data),
        )
