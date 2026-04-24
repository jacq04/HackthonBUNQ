"""Shared tool belt.

Every state-modifying tool is logged to public.audit_log. Agents can only move
money via tools defined here — never via free-text inference.
"""
from __future__ import annotations

import uuid
from typing import Any

from app.db import get_supabase


async def audit(
    *, actor: str, action: str, resource_type: str | None, resource_id: str | None, diff: dict[str, Any]
) -> None:
    """Insert an audit_log row. Safe to call from any agent tool."""
    sb = get_supabase()
    sb.table("audit_log").insert(
        {
            "actor": actor,
            "action": action,
            "resource_type": resource_type,
            "resource_id": resource_id,
            "diff": diff,
        }
    ).execute()


async def emit_event(group_id: uuid.UUID | str, *, type: str, payload: dict[str, Any]) -> None:
    """Write a row to events — Supabase Realtime fans it out to subscribed clients."""
    sb = get_supabase()
    sb.table("events").insert(
        {"group_id": str(group_id), "type": type, "payload": payload}
    ).execute()


async def post_agent_message(
    group_id: uuid.UUID | str,
    *,
    agent_name: str,
    text: str,
    channel: str = "group",
    recipient_user_id: uuid.UUID | str | None = None,
    metadata: dict[str, Any] | None = None,
) -> None:
    sb = get_supabase()
    sb.table("messages").insert(
        {
            "group_id": str(group_id),
            "agent_name": agent_name,
            "channel": channel,
            "recipient_user_id": str(recipient_user_id) if recipient_user_id else None,
            "text": text,
            "metadata": metadata or {},
        }
    ).execute()


async def fetch_charter(group_id: uuid.UUID | str) -> dict[str, Any] | None:
    sb = get_supabase()
    r = (
        sb.table("charters")
        .select("content,version,finalized_at")
        .eq("group_id", str(group_id))
        .order("version", desc=True)
        .limit(1)
        .execute()
    )
    return r.data[0] if r.data else None


async def fetch_group(group_id: uuid.UUID | str) -> dict[str, Any] | None:
    sb = get_supabase()
    r = sb.table("groups").select("*").eq("id", str(group_id)).single().execute()
    return r.data


async def fetch_members(group_id: uuid.UUID | str) -> list[dict[str, Any]]:
    sb = get_supabase()
    r = sb.table("members").select("*,users(display_name,language)").eq("group_id", str(group_id)).execute()
    return r.data or []
