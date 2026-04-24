"""Dispute routes — invokes the Mediator agent."""
from __future__ import annotations

import uuid
from typing import Any

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from app.agents.mediator import get_mediator
from app.agents.tools import post_agent_message
from app.auth import CurrentUserId
from app.db import get_supabase

router = APIRouter(prefix="/groups/{group_id}/disputes", tags=["disputes"])


class CreateDisputeBody(BaseModel):
    respondent_user_id: uuid.UUID | None = None
    amount_cents: int | None = Field(default=None, ge=0)
    claim_text: str = Field(min_length=1, max_length=2000)
    evidence_urls: list[str] = Field(default_factory=list, max_length=6)


@router.post("")
async def create_dispute(
    group_id: uuid.UUID, body: CreateDisputeBody, user_id: CurrentUserId
) -> dict[str, Any]:
    sb = get_supabase()

    dispute = {
        "id": str(uuid.uuid4()),
        "group_id": str(group_id),
        "claimant_user_id": str(user_id),
        "respondent_user_id": str(body.respondent_user_id) if body.respondent_user_id else None,
        "amount_cents": body.amount_cents,
        "status": "open",
        "evidence_urls": body.evidence_urls,
    }
    sb.table("disputes").insert(dispute).execute()

    # Run the Mediator agent with the claimant's statement + evidence URLs.
    mediator_input = (
        f"{body.claim_text}\n\nEvidence URLs: {body.evidence_urls}\n"
        f"Dispute ID: {dispute['id']}"
    )
    result = await get_mediator().run(
        mediator_input,
        context={
            "group_id": group_id,
            "dispute_id": uuid.UUID(dispute["id"]),
            "claimant_user_id": str(user_id),
        },
    )

    # Mediator already posted its public message inside propose_resolution.
    return {
        "dispute_id": dispute["id"],
        "mediator_reply": result.text,
        "tool_calls": result.tool_calls,
    }


@router.get("")
async def list_disputes(group_id: uuid.UUID, user_id: CurrentUserId) -> list[dict[str, Any]]:
    sb = get_supabase()
    r = sb.table("disputes").select("*").eq("group_id", str(group_id)).order("created_at", desc=True).execute()
    return r.data or []
