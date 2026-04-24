"""Charter drafting routes — invokes the Constitution agent.

POST  /groups/{id}/charter/messages   Add a founder turn, get the agent reply
GET   /groups/{id}/charter            Return the latest charter draft
POST  /groups/{id}/charter/sign       Record a member signature
"""
from __future__ import annotations

import uuid

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from app.agents.base import AgentResult
from app.agents.constitution import get_constitution, load_charter_preamble
from app.agents.tools import post_agent_message
from app.auth import CurrentUserId
from app.db import get_supabase

router = APIRouter(prefix="/groups/{group_id}/charter", tags=["charter"])


class CharterMessageBody(BaseModel):
    text: str = Field(min_length=1, max_length=4000)


class CharterMessageResponse(BaseModel):
    agent_reply: str
    draft: dict | None
    finalized: bool


@router.post("/messages", response_model=CharterMessageResponse)
async def send_charter_message(
    group_id: uuid.UUID, body: CharterMessageBody, user_id: CurrentUserId
) -> CharterMessageResponse:
    sb = get_supabase()

    # Persist the founder's message first.
    sb.table("messages").insert(
        {
            "group_id": str(group_id),
            "sender_user_id": str(user_id),
            "channel": "group",
            "text": body.text,
            "metadata": {"surface": "charter_dialog"},
        }
    ).execute()

    # Load prior dialog for this group's charter channel.
    prior = (
        sb.table("messages")
        .select("sender_user_id,agent_name,text")
        .eq("group_id", str(group_id))
        .order("created_at")
        .execute()
    )
    history: list[dict] = []
    preamble = await load_charter_preamble(group_id)
    if preamble:
        history.append({"role": "user", "content": f"<context>\n{preamble}\n</context>"})
    for m in (prior.data or [])[:-1]:  # exclude the just-added message
        role = "assistant" if m.get("agent_name") == "constitution" else "user"
        history.append({"role": role, "content": m["text"]})

    agent = get_constitution()
    result: AgentResult = await agent.run(
        body.text, history=history, context={"group_id": group_id}
    )

    # Persist agent reply.
    await post_agent_message(
        group_id, agent_name="constitution", text=result.text,
        metadata={"tool_calls": result.tool_calls},
    )

    # Inspect tool calls to decide draft / finalize state.
    finalized = any(c["name"] == "finalize_charter" for c in result.tool_calls)
    draft_tool_calls = [c for c in result.tool_calls if c["name"] == "draft_charter"]
    draft = draft_tool_calls[-1]["input"] if draft_tool_calls else None

    return CharterMessageResponse(agent_reply=result.text, draft=draft, finalized=finalized)


@router.get("")
async def get_charter(group_id: uuid.UUID, user_id: CurrentUserId) -> dict:
    sb = get_supabase()
    r = (
        sb.table("charters")
        .select("*")
        .eq("group_id", str(group_id))
        .order("version", desc=True)
        .limit(1)
        .execute()
    )
    if not r.data:
        raise HTTPException(status_code=404, detail="no charter yet")
    return r.data[0]


class SignBody(BaseModel):
    accept: bool = True


@router.post("/sign")
async def sign_charter(group_id: uuid.UUID, body: SignBody, user_id: CurrentUserId) -> dict:
    sb = get_supabase()
    r = (
        sb.table("charters")
        .select("id,signed_by,finalized_at")
        .eq("group_id", str(group_id))
        .order("version", desc=True)
        .limit(1)
        .execute()
    )
    if not r.data:
        raise HTTPException(status_code=404, detail="no charter to sign")
    row = r.data[0]
    if not body.accept:
        return {"ok": False, "signed_by": row["signed_by"]}

    signed = set(row.get("signed_by") or [])
    signed.add(str(user_id))
    sb.table("charters").update({"signed_by": list(signed)}).eq("id", row["id"]).execute()
    return {"ok": True, "signed_by": list(signed), "finalized": bool(row.get("finalized_at"))}
