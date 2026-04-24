"""Contribution flow.

POST /groups/{id}/contribute
  1. Create bunq request-inquiry addressed to the user.
  2. Create TB pending transfers (gateway -> pool, gateway -> member_contrib) as a linked pair.
  3. Persist a contributions row bridging bunq_request_inquiry_id -> TB pending ids.
  4. Return the bunq request URL for the mobile client to open.

The actual TB post happens in /webhooks/bunq when the payment lands.
"""
from __future__ import annotations

import uuid
from typing import Any

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from app.agents.tools import emit_event
from app.auth import CurrentUserId
from app.bunq import get_bunq_client
from app.db import get_supabase
from app.ledger.tb_client import (
    FLAG_LINKED,
    TRANSFER_FLAG_LINKED,
    TRANSFER_FLAG_PENDING,
    AccountCode,
    TransferCode,
    account_id_for,
    get_tb_client,
)
from app.ledger.tb_two_phase import TransferLeg
from app.utils.ids import new_tb_id
from app.utils.logging import get_logger

log = get_logger(__name__)
router = APIRouter(prefix="/groups/{group_id}/contribute", tags=["contribute"])


class ContributeBody(BaseModel):
    amount_cents: int | None = Field(default=None, ge=100)
    cycle_month: int = Field(default=0, ge=0, le=24)
    # Supply the user's bunq email so bunq knows where to send the request.
    counterparty_email: str | None = None


class ContributeResponse(BaseModel):
    contribution_id: uuid.UUID
    bunq_request_inquiry_id: str | None
    bunq_pay_url: str | None
    tb_pending_pool_id: str
    tb_pending_member_id: str


@router.post("", response_model=ContributeResponse)
async def create_contribution(
    group_id: uuid.UUID, body: ContributeBody, user_id: CurrentUserId
) -> ContributeResponse:
    sb = get_supabase()

    # 1. Load group + member context.
    g = sb.table("groups").select("*").eq("id", str(group_id)).single().execute()
    if not g.data:
        raise HTTPException(status_code=404, detail="group not found")
    group = g.data

    m = (
        sb.table("members")
        .select("*,users(display_name,language)")
        .eq("group_id", str(group_id))
        .eq("user_id", str(user_id))
        .single()
        .execute()
    )
    if not m.data:
        raise HTTPException(status_code=403, detail="not a member")

    amount = body.amount_cents or group["contribution_amount_cents"]

    # 2. Create the two PENDING TB transfers as a linked pair.
    pool_id = int(group["tb_pool_account_id"])
    gateway_id = int(group["tb_gateway_account_id"])
    member_contrib_id = int(m.data["tb_contrib_account_id"])

    pending_pool_id, pending_member_id = _create_linked_pending_pair(
        group_id=group_id,
        cycle_month=body.cycle_month,
        amount_cents=amount,
        gateway=gateway_id,
        pool=pool_id,
        member_contrib=member_contrib_id,
    )

    # 3. bunq request-inquiry (best-effort in dev; stays None if bunq not configured).
    bunq_request_id: str | None = None
    bunq_pay_url: str | None = None
    if group.get("bunq_account_id"):
        try:
            email = body.counterparty_email
            if not email:
                raise RuntimeError("counterparty_email required when bunq is configured")
            resp = await get_bunq_client().create_request_inquiry(
                from_account_id=int(group["bunq_account_id"]),
                amount_cents=amount,
                counterparty_email=email,
                description=_bunq_description(group_id, user_id, body.cycle_month),
                currency=group["currency"],
            )
            bunq_request_id = str(resp.get("id") or "")
            bunq_pay_url = (resp.get("bunqme_share_url") or {}).get("url") if isinstance(
                resp.get("bunqme_share_url"), dict
            ) else resp.get("bunqme_share_url")
        except Exception as e:  # noqa: BLE001
            log.warning("contribute.bunq_failed", error=str(e))

    # 4. Persist contributions row.
    row = {
        "id": str(uuid.uuid4()),
        "group_id": str(group_id),
        "user_id": str(user_id),
        "cycle_month": body.cycle_month,
        "amount_cents": amount,
        "bunq_request_inquiry_id": bunq_request_id,
        "tb_pending_pool_id": pending_pool_id,
        "tb_pending_member_id": pending_member_id,
        "status": "pending",
    }
    sb.table("contributions").insert(row).execute()

    await emit_event(
        group_id,
        type="contribution.pending",
        payload={
            "contribution_id": row["id"],
            "user_id": str(user_id),
            "amount_cents": amount,
            "cycle_month": body.cycle_month,
        },
    )

    return ContributeResponse(
        contribution_id=uuid.UUID(row["id"]),
        bunq_request_inquiry_id=bunq_request_id,
        bunq_pay_url=bunq_pay_url,
        tb_pending_pool_id=str(pending_pool_id),
        tb_pending_member_id=str(pending_member_id),
    )


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
def _bunq_description(group_id: uuid.UUID, user_id: uuid.UUID, cycle_month: int) -> str:
    return f"Kitty|{group_id}|{user_id}|{cycle_month}"


def parse_bunq_description(description: str) -> dict[str, Any] | None:
    parts = (description or "").split("|")
    if len(parts) != 4 or parts[0] != "Kitty":
        return None
    try:
        return {
            "group_id": uuid.UUID(parts[1]),
            "user_id": uuid.UUID(parts[2]),
            "cycle_month": int(parts[3]),
        }
    except Exception:  # noqa: BLE001
        return None


def _create_linked_pending_pair(
    *,
    group_id: uuid.UUID,
    cycle_month: int,
    amount_cents: int,
    gateway: int,
    pool: int,
    member_contrib: int,
) -> tuple[int, int]:
    """Create two PENDING transfers atomically: pool-side + member-side.

    Both debit the bunq_gateway account so the pool invariant
    (`debits_must_not_exceed_credits`) holds — the gateway provides the credit
    side of both internal transfers, mirroring money that has arrived on bunq.
    """
    import tigerbeetle as tb  # type: ignore[import-not-found]

    from app.ledger.tb_client import LEDGER_EUR

    group_ud128 = int.from_bytes(group_id.bytes, "big")
    pool_transfer_id = new_tb_id()
    member_transfer_id = new_tb_id()

    transfers = [
        tb.Transfer(
            id=pool_transfer_id,
            debit_account_id=gateway,
            credit_account_id=pool,
            amount=amount_cents,
            pending_id=0,
            user_data_128=group_ud128,
            user_data_64=cycle_month,
            user_data_32=0,
            timeout=0,
            ledger=LEDGER_EUR,
            code=TransferCode.CONTRIBUTION,
            flags=TRANSFER_FLAG_PENDING | TRANSFER_FLAG_LINKED,
        ),
        tb.Transfer(
            id=member_transfer_id,
            debit_account_id=gateway,
            credit_account_id=member_contrib,
            amount=amount_cents,
            pending_id=0,
            user_data_128=group_ud128,
            user_data_64=cycle_month,
            user_data_32=0,
            timeout=0,
            ledger=LEDGER_EUR,
            code=TransferCode.CONTRIBUTION,
            flags=TRANSFER_FLAG_PENDING,
        ),
    ]

    errors = get_tb_client().create_transfers(transfers)
    if errors:
        raise RuntimeError(
            f"TB linked pending pair failed: {[(e.index, str(e.result)) for e in errors]}"
        )
    return pool_transfer_id, member_transfer_id
