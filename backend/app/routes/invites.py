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
from app.ledger.tb_client import (
    AccountCode,
    TransferCode,
    account_id_for,
    create_group_accounts,
    create_member_accounts,
)
from app.ledger.tb_two_phase import TransferLeg, linked_batch
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

    # ── First debit on accept ─────────────────────────────────────────────
    # The real-world mandate pulls on debit_day, but in the sandbox we fire
    # the first contribution immediately so the user sees their pot-share
    # land. Gateway mirrors what bunq will pull; pool accumulates it.
    contribution_cents = int(group_row["contribution_amount_cents"])
    try:
        linked_batch(
            [
                TransferLeg(
                    int(group_row["tb_gateway_account_id"]),
                    int(group_row["tb_pool_account_id"]),
                    contribution_cents,
                    TransferCode.CONTRIBUTION,
                ),
                TransferLeg(
                    int(group_row["tb_gateway_account_id"]),
                    # member_contrib account is the per-(group, member) tracker.
                    account_id_for(
                        group_id, AccountCode.MEMBER_CONTRIB, user_id
                    ),
                    contribution_cents,
                    TransferCode.CONTRIBUTION,
                ),
            ],
            group_id=group_id,
            cycle_month=1,
        )
        # Persist a `contributions` row so the admin dashboard's money-flow
        # rollup (contributions count + sum) reflects the inflow. Status is
        # 'posted' because the TB linked_batch above already committed.
        contribution_row_id = str(uuid.uuid4())
        sb.table("contributions").insert(
            {
                "id": contribution_row_id,
                "group_id": str(group_id),
                "user_id": str(user_id),
                "cycle_month": 1,
                "amount_cents": contribution_cents,
                "status": "posted",
                "posted_at": datetime.now(timezone.utc).isoformat(),
            }
        ).execute()

        await emit_event(
            group_id,
            type="contribution.posted",
            payload={
                "user_id": str(user_id),
                "amount_cents": contribution_cents,
                "cycle_month": 1,
                "contribution_id": contribution_row_id,
                "reason": "first debit on accept",
            },
        )

        # Move actual euros: member.bunq → platform.bunq.
        # The TB leg above is the source-of-truth ledger; this is the
        # real-money mirror so funds land in Asha's collection account.
        try:
            from app.config import settings

            platform_client = get_bunq_client(settings.bunq_platform_label)
            await platform_client.ensure_session()
            platform_acct_id = await platform_client.get_primary_account_id()
            platform_iban: str | None = None
            for a in await platform_client.list_monetary_accounts():
                if a.get("id") == platform_acct_id:
                    for alias in a.get("alias") or []:
                        if alias.get("type") == "IBAN":
                            platform_iban = alias.get("value")
                            break
                    break
            platform_name = settings.bunq_platform_label
            if not platform_iban:
                raise RuntimeError("platform IBAN missing — run bunq bootstrap")

            if bunq_label:
                user_client = get_bunq_client(bunq_label)
                await user_client.ensure_session()
                user_acct_id = await user_client.get_primary_account_id()
                pay = await user_client.make_payment(
                    from_account_id=user_acct_id,
                    amount_cents=contribution_cents,
                    counterparty_iban=platform_iban,
                    counterparty_name=platform_name,
                    description=f"Kitty · {group_row['name']} · cycle 1",
                )
                await emit_event(
                    group_id,
                    type="bunq.payment.posted",
                    payload={
                        "user_id": str(user_id),
                        "amount_cents": contribution_cents,
                        "bunq_payment_id": pay.get("id"),
                        "to_iban": platform_iban,
                    },
                )
        except Exception as e:  # noqa: BLE001
            log.error("invites.bunq_payment_failed", error=str(e))
    except Exception as e:  # noqa: BLE001
        log.error("invites.first_debit_failed", error=str(e))

    # Did we just cross the chartered threshold? If so, auto-start — no
    # separate platform tick needed for the happy path.
    counts = _counts(sb, group_id)
    new_group_status = group_row["status"]
    if counts["accepted"] >= int(group_row["cycle_count"]):
        _transition_to_chartered(sb, group_id, int(group_row["cycle_count"]))
        new_group_status = "chartered"
        # Auto-start: chartered → active + seed cycles.
        try:
            from app.routes.circle_lifecycle import StartBody, start_circle

            # Call the same handler used by POST /groups/{id}/start so the
            # behavior stays in one place. Use an admin user_id; the service
            # role + RLS mean we're fine.
            await start_circle(group_id, StartBody(), user_id)
            new_group_status = "active"
            await emit_event(
                group_id,
                type="group.auto_started",
                payload={"by": "accept-threshold"},
            )
        except Exception as e:  # noqa: BLE001
            log.error("invites.autostart_failed", error=str(e))

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
    required headcount so the buffer doesn't create ghost members. Retired
    invitees go back on the global waitlist (waitlist_status='waiting') with
    their original match_preferences intact, so the Matchmaker can match
    them to a different pod on the next run."""
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
        retired_user_ids = [row["user_id"] for row in excess.data]
        sb.table("members").update({"status": "exited_clean"}).eq(
            "group_id", str(group_id)
        ).in_("status", ["invited"]).execute()
        # Put them back on the waitlist so Matchmaker re-considers them.
        from datetime import datetime, timezone

        sb.table("users").update(
            {
                "waitlist_status": "waiting",
                "waitlist_since": datetime.now(timezone.utc).isoformat(),
            }
        ).in_("id", retired_user_ids).execute()
        sb.table("events").insert(
            {
                "group_id": str(group_id),
                "type": "invite.retired",
                "payload": {
                    "user_ids": retired_user_ids,
                    "reason": "pod chartered without them",
                },
            }
        ).execute()
        log.info(
            "invites.retired_buffer",
            group_id=str(group_id),
            count=len(retired_user_ids),
        )
