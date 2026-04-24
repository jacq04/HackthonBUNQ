"""Emergency exit routes — invokes the Emergency agent."""
from __future__ import annotations

import uuid
from typing import Any

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from app.agents.emergency import get_emergency
from app.auth import CurrentUserId
from app.db import get_supabase

router = APIRouter(prefix="/groups/{group_id}/emergencies", tags=["emergencies"])


class CreateEmergencyBody(BaseModel):
    reason: str = Field(min_length=1, max_length=1000)


@router.post("")
async def request_emergency_exit(
    group_id: uuid.UUID, body: CreateEmergencyBody, user_id: CurrentUserId
) -> dict[str, Any]:
    sb = get_supabase()
    emergency_id = str(uuid.uuid4())
    sb.table("emergencies").insert(
        {
            "id": emergency_id,
            "group_id": str(group_id),
            "user_id": str(user_id),
            "reason": body.reason,
            "status": "open",
        }
    ).execute()

    prompt = (
        f"Member {user_id} has requested an emergency exit. Reason:\n{body.reason}\n\n"
        f"Emergency ID: {emergency_id}. Begin by computing the buyout."
    )
    result = await get_emergency().run(
        prompt,
        context={
            "group_id": group_id,
            "emergency_id": uuid.UUID(emergency_id),
            "user_id": str(user_id),
        },
    )
    return {
        "emergency_id": emergency_id,
        "agent_reply": result.text,
        "tool_calls": result.tool_calls,
    }


class ConsentBody(BaseModel):
    approve: bool


@router.post("/{emergency_id}/consent")
async def record_consent(
    group_id: uuid.UUID,
    emergency_id: uuid.UUID,
    body: ConsentBody,
    user_id: CurrentUserId,
) -> dict[str, Any]:
    sb = get_supabase()
    r = (
        sb.table("emergencies")
        .select("group_consent_user_ids,status,buyout_amount_proposed_cents,user_id")
        .eq("id", str(emergency_id))
        .single()
        .execute()
    )
    if not r.data:
        raise HTTPException(status_code=404, detail="not found")
    if r.data["status"] != "open":
        raise HTTPException(status_code=400, detail=f"emergency is {r.data['status']}")
    if not body.approve:
        return {"ok": True, "approved": False}

    consents = set(r.data.get("group_consent_user_ids") or [])
    consents.add(str(user_id))
    sb.table("emergencies").update({"group_consent_user_ids": list(consents)}).eq(
        "id", str(emergency_id)
    ).execute()

    # How many active members (excluding the exiter) total?
    members = (
        sb.table("members")
        .select("user_id")
        .eq("group_id", str(group_id))
        .eq("status", "active")
        .execute()
    )
    remaining = {m["user_id"] for m in (members.data or [])} - {r.data["user_id"]}

    if consents >= remaining:
        # Consensus reached — ask the agent to execute.
        result = await get_emergency().run(
            "Consent threshold reached. Execute the buyout now using the refund amount "
            f"({r.data['buyout_amount_proposed_cents']} cents) for user {r.data['user_id']}.",
            context={
                "group_id": group_id,
                "emergency_id": emergency_id,
                "user_id": r.data["user_id"],
            },
        )
        return {
            "ok": True,
            "approved": True,
            "consensus_reached": True,
            "agent_reply": result.text,
            "tool_calls": result.tool_calls,
        }

    return {
        "ok": True,
        "approved": True,
        "consensus_reached": False,
        "consents": len(consents),
        "required": len(remaining),
    }
