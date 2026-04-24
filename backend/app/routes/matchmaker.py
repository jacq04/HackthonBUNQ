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

from fastapi import APIRouter
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
    action: Literal["joined", "formed", "waitlisted", "none"]
    group_id: str | None = None
    group_name: str | None = None
    payout_cycle: int | None = None
    trust_score: int
    rationale: str


@router.post("/find-circle", response_model=FindCircleResponse)
async def find_circle(body: FindCircleRequest, user_id: CurrentUserId) -> FindCircleResponse:
    sb = get_supabase()

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
        "Call list_open_circles and list_waitlist, then decide: JOIN, FORM, or WAITLIST. "
        "Finish with exactly one of propose_join_existing / form_new_circle / add_to_waitlist."
    )
    result = await get_matchmaker().run(prompt, context={"user_id": user_id})

    # 4. Extract the decision from tool_calls.
    action: Literal["joined", "formed", "waitlisted", "none"] = "none"
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
        elif tc["name"] == "form_new_circle":
            action = "formed"
            rationale = tc["input"].get("rationale", "")
            r = tc.get("result") or {}
            group_id = r.get("group_id")
            group_name = tc["input"].get("name")
            payout_cycle = 1  # founder / requester always lands at cycle 1
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
