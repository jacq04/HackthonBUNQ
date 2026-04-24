"""Generic group-chat routing — Router agent picks the next specialist.

POST /groups/{id}/chat    Post a user message, returns routed agent's reply.
"""
from __future__ import annotations

import uuid
from typing import Any

from fastapi import APIRouter
from pydantic import BaseModel, Field

from app.agents.router import get_router
from app.agents.tools import post_agent_message
from app.auth import CurrentUserId
from app.db import get_supabase

router = APIRouter(prefix="/groups/{group_id}/chat", tags=["chat"])


class ChatBody(BaseModel):
    text: str = Field(min_length=1, max_length=4000)


class ChatResponse(BaseModel):
    intent: str
    confidence: float
    rationale: str
    routed_to: str


@router.post("", response_model=ChatResponse)
async def send_chat(group_id: uuid.UUID, body: ChatBody, user_id: CurrentUserId) -> ChatResponse:
    sb = get_supabase()
    sb.table("messages").insert(
        {
            "group_id": str(group_id),
            "sender_user_id": str(user_id),
            "channel": "group",
            "text": body.text,
        }
    ).execute()

    r = await get_router().run(body.text, context={"group_id": group_id})
    decision: dict[str, Any] = {"intent": "unknown", "confidence": 0.0, "rationale": ""}
    for tc in r.tool_calls:
        if tc["name"] == "classify":
            decision = tc["input"]
            break

    await post_agent_message(
        group_id,
        agent_name="router",
        channel="private",
        recipient_user_id=user_id,
        text=f"routed: {decision['intent']} (conf={decision['confidence']:.2f}) — {decision['rationale']}",
        metadata={"internal": True},
    )

    return ChatResponse(
        intent=decision["intent"],
        confidence=decision["confidence"],
        rationale=decision["rationale"],
        routed_to=decision["intent"],
    )
