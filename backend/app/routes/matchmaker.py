"""Matchmaker entry point — the only way a user can "start" a circle.

POST /matchmaker/find-circle  body: preferences  → runs Vetting + Matchmaker

  1. Save the user's match_preferences + goal on public.users.
  2. If no trust_score exists yet, run the Vetting agent.
  3. Run the Matchmaker agent — it decides JOIN / FORM / WAITLIST.
  4. Return the outcome. Client navigates the user to the right screen.
"""
from __future__ import annotations

import uuid
from typing import Literal

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from app.agents.matchmaker import get_matchmaker
from app.agents.vetting import get_vetting
from app.auth import CurrentUserId
from app.db import get_supabase
from app.utils.logging import get_logger

log = get_logger(__name__)
router = APIRouter(prefix="/matchmaker", tags=["matchmaker"])


class FindCircleRequest(BaseModel):
    contribution_amount_cents: int = Field(ge=500, le=100000)
    cycle_count: int = Field(ge=2, le=24)
    goal: str = Field(min_length=2, max_length=200)
    urgency: Literal["low", "medium", "high"] = "medium"
    cultural_hint: str | None = None


class FindCircleResponse(BaseModel):
    action: Literal["joined", "filled", "waitlisted", "none"]
    group_id: str | None = None
    group_name: str | None = None
    payout_cycle: int | None = None
    trust_score: int
    rationale: str


@router.post("/find-circle", response_model=FindCircleResponse)
async def find_circle(body: FindCircleRequest, user_id: CurrentUserId) -> FindCircleResponse:
    sb = get_supabase()

    # Platform admins run circles; they don't join them. Refuse upfront so the
    # admin can't accidentally end up in the founding set.
    me = (
        sb.table("users")
        .select("is_admin")
        .eq("id", str(user_id))
        .single()
        .execute()
    )
    if (me.data or {}).get("is_admin"):
        raise HTTPException(
            status_code=403,
            detail="admins manage the platform — they don't join circles",
        )

    # If the user is already invited/accepted/active in a non-archived pod,
    # short-circuit. Otherwise the run below would clobber their
    # waitlist_status='matched' back to 'waiting' (the matchmaker finds no
    # eligible circle because they're already in one) and they'd reappear
    # in the admin waitlist tab even though they have an active membership.
    existing = (
        sb.table("members")
        .select(
            "group_id,status,payout_cycle,"
            "groups!inner(id,name,status)"
        )
        .eq("user_id", str(user_id))
        .in_("status", ["invited", "accepted", "active", "received"])
        .execute()
        .data
        or []
    )
    live = [
        row
        for row in existing
        if (row.get("groups") or {}).get("status")
        not in ("archived", "completed", "cancelled")
    ]
    if live:
        # Prefer an active/accepted membership over an invited one so the
        # client lands on the actual group screen; the invited case still
        # surfaces the group_id (the client can route to the accept page).
        priority = {"active": 0, "received": 0, "accepted": 1, "invited": 2}
        live.sort(key=lambda r: priority.get(r["status"], 9))
        pick = live[0]
        g = pick.get("groups") or {}
        u_existing = (
            sb.table("users")
            .select("trust_score")
            .eq("id", str(user_id))
            .single()
            .execute()
            .data
            or {}
        )
        return FindCircleResponse(
            action="joined",
            group_id=g.get("id"),
            group_name=g.get("name"),
            payout_cycle=pick.get("payout_cycle"),
            trust_score=int(u_existing.get("trust_score") or 50),
            rationale=(
                f"Already a {pick['status']} member of {g.get('name')!r} — "
                "open the pod instead of re-running the matchmaker."
            ),
        )

    # 1. Persist preferences + goal so Matchmaker + peer Matchmakers see them.
    prefs = {
        "contribution_amount_cents": body.contribution_amount_cents,
        "cycle_count": body.cycle_count,
        "urgency": body.urgency,
        "cultural_hint": body.cultural_hint,
    }
    sb.table("users").update(
        {
            "match_preferences": prefs,
            "goal": body.goal,
            "waitlist_status": "waiting",
            "waitlist_since": "now()",
        }
    ).eq("id", str(user_id)).execute()

    # 2. Vetting — compute trust_score if absent.
    u = sb.table("users").select("trust_score,bunq_label").eq("id", str(user_id)).single().execute()
    trust = int((u.data or {}).get("trust_score") or 50)
    bunq_label = (u.data or {}).get("bunq_label")
    if trust == 50:  # default → run vetting
        log.info("matchmaker.run_vetting", user_id=str(user_id))
        await get_vetting().run(
            (
                f"Score this prospective member. user_id={user_id}. "
                f"Goal: {body.goal!r}. Amount: €{body.contribution_amount_cents / 100:.2f}. "
                f"Urgency: {body.urgency}. Cultural hint: {body.cultural_hint!r}. "
                f"Follow the 3-tool process (summary, history, record)."
            ),
            context={"user_id": user_id, "bunq_label": bunq_label},
        )
        # Refetch.
        u = sb.table("users").select("trust_score,trust_rationale").eq("id", str(user_id)).single().execute()
        trust = int((u.data or {}).get("trust_score") or 50)

    # 3. Matchmaker — decide action.
    prompt = (
        f"A user is looking for a circle. user_id={user_id}.\n"
        f"Preferences: {prefs}\n"
        f"Goal: {body.goal!r}\n"
        f"Trust score: {trust}\n\n"
        "Call list_open_circles AND list_waitlist, then decide:\n"
        "  - FILL (preferred when seats_open == 1 + count of compatible "
        "waitlist matches): propose_fill_circle(group_id=, "
        "additional_user_ids=[...]).\n"
        "  - JOIN (single open seat, no other waitlist need): "
        "propose_join_existing(group_id=).\n"
        "  - WAITLIST (no eligible circle): add_to_waitlist(rationale=).\n"
        "NEVER attempt to form a new circle — circle creation is admin-only."
    )
    try:
        result = await get_matchmaker().run(prompt, context={"user_id": user_id})
    except Exception as e:  # noqa: BLE001
        # Record the failure as a matchmaker audit row so the admin
        # control-room reflects it.
        sb.table("audit_log").insert(
            {
                "actor": "agent:matchmaker",
                "action": "matchmaker.error",
                "resource_type": "user",
                "resource_id": str(user_id),
                "diff": {"ok": False, "error": str(e)[:500]},
            }
        ).execute()
        log.exception("matchmaker.run_failed", user_id=str(user_id))
        raise HTTPException(
            status_code=502,
            detail=f"matchmaker run failed: {e}",
        ) from e

    # Record the run summary itself (separate from per-tool audit rows the
    # agent already writes) so the dashboard sees a one-line "matchmaker.run".
    sb.table("audit_log").insert(
        {
            "actor": "agent:matchmaker",
            "action": "matchmaker.run",
            "resource_type": "user",
            "resource_id": str(user_id),
            "diff": {
                "ok": True,
                "tool_calls": len(result.tool_calls),
                "preferences": prefs,
            },
        }
    ).execute()

    # 4. Extract the decision from tool_calls.
    action: Literal["joined", "filled", "waitlisted", "none"] = "none"
    group_id: str | None = None
    group_name: str | None = None
    payout_cycle: int | None = None
    rationale = ""
    for tc in result.tool_calls:
        if tc["name"] == "propose_join_existing":
            action = "joined"
            group_id = tc["input"].get("group_id")
            rationale = tc["input"].get("rationale", "")
            payout_cycle = (tc.get("result") or {}).get("payout_cycle")
        elif tc["name"] == "propose_fill_circle":
            r = tc.get("result") or {}
            if r.get("ok"):
                action = "filled"
                group_id = tc["input"].get("group_id")
                rationale = tc["input"].get("rationale", "")
        elif tc["name"] == "add_to_waitlist":
            action = "waitlisted"
            rationale = tc["input"].get("rationale", "")

    if group_id and not group_name:
        g = sb.table("groups").select("name").eq("id", group_id).single().execute()
        group_name = (g.data or {}).get("name")

    return FindCircleResponse(
        action=action,
        group_id=group_id,
        group_name=group_name,
        payout_cycle=payout_cycle,
        trust_score=trust,
        rationale=rationale,
    )
