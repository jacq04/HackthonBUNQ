"""/me/* — the signed-in user's bunq wallet.

    GET /me/accounts       every ACTIVE+INACTIVE monetary account + balance
    GET /me/transactions   recent payments (last N days, all or one account)
    GET /me/profile        display_name + phone + IBAN + trust_score, used for the
                           pod landing page header

All three routes require a Supabase JWT; they read the user's bunq_label from
public.users and use the per-label cached bunq session.
"""
from __future__ import annotations

import uuid
from datetime import datetime, timedelta, timezone
from typing import Any

from fastapi import APIRouter, HTTPException, Query

from app.auth import CurrentUserId
from app.bunq import get_bunq_client
from app.db import get_supabase
from app.utils.logging import get_logger

log = get_logger(__name__)
router = APIRouter(prefix="/me", tags=["me"])


async def _bunq_label_for(sb: Any, user_id: uuid.UUID) -> str:
    r = (
        sb.table("users")
        .select("bunq_label")
        .eq("id", str(user_id))
        .single()
        .execute()
    )
    label = (r.data or {}).get("bunq_label")
    if not label:
        raise HTTPException(
            status_code=409,
            detail="this account is not linked to a bunq identity — sign in with phone",
        )
    return label


@router.get("/profile")
async def get_profile(user_id: CurrentUserId) -> dict[str, Any]:
    sb = get_supabase()
    row = (
        sb.table("users")
        .select(
            "display_name,bunq_label,bunq_user_id,trust_score,goal,is_admin,"
            "waitlist_status,waitlist_since,match_preferences"
        )
        .eq("id", str(user_id))
        .single()
        .execute()
    )
    me = row.data or {}

    # If the user is on the waitlist, surface the top-3 best-fit recruiting
    # circles so the wallet can show "Matchmaker is searching — these circles
    # match your goal".
    candidate_circles: list[dict[str, Any]] = []
    if me.get("waitlist_status") == "waiting":
        prefs = me.get("match_preferences") or {}
        cand_trust = int(me.get("trust_score") or 50)
        circles = (
            sb.table("groups")
            .select(
                "id,name,status,theme,contribution_amount_cents,cycle_count,"
                "min_trust_score,max_members,description"
            )
            .in_("status", ["recruiting", "awaiting_accepts", "active"])
            .execute()
            .data
            or []
        )
        want_cycles = prefs.get("cycle_count")
        want_amount = prefs.get("contribution_amount_cents")
        for c in circles:
            cap = c.get("max_members") or c["cycle_count"]
            if cand_trust < int(c.get("min_trust_score") or 0):
                continue
            # Hard match — same cycle_count and ±15% amount.
            if want_cycles and int(want_cycles) != c["cycle_count"]:
                continue
            if want_amount:
                lo = int(want_amount) * 0.85
                hi = int(want_amount) * 1.15
                if not (lo <= c["contribution_amount_cents"] <= hi):
                    continue
            score = 1
            if want_amount and abs(
                int(want_amount) - c["contribution_amount_cents"]
            ) < 2500:
                score += 2
            if (prefs.get("cultural_hint") or "") and c.get("cultural_hint") and \
                    prefs["cultural_hint"].lower() in (c["cultural_hint"] or "").lower():
                score += 2
            candidate_circles.append({**c, "capacity": cap, "fit_score": score})
        candidate_circles.sort(key=lambda x: -x["fit_score"])
        candidate_circles = candidate_circles[:3]
    client = get_bunq_client(me.get("bunq_label") or "default")
    phone: str | None = None
    primary_iban: str | None = None
    try:
        await client.ensure_session()
        p = await client.get_user_profile()
        for alias in p.get("alias") or []:
            if alias.get("type") == "PHONE_NUMBER" and not phone:
                phone = alias.get("value")
        accounts = await client.list_monetary_accounts()
        for a in accounts:
            if a.get("status") == "ACTIVE":
                for al in a.get("alias") or []:
                    if al.get("type") == "IBAN" and not primary_iban:
                        primary_iban = al.get("value")
                break
    except Exception as e:  # noqa: BLE001
        log.warning("me.profile.bunq_failed", error=str(e))

    return {
        "user_id": str(user_id),
        "display_name": me.get("display_name"),
        "bunq_user_id": me.get("bunq_user_id"),
        "trust_score": me.get("trust_score"),
        "goal": me.get("goal"),
        "phone": phone,
        "primary_iban": primary_iban,
        "is_admin": bool(me.get("is_admin")),
        "waitlist_status": me.get("waitlist_status"),
        "waitlist_since": me.get("waitlist_since"),
        "match_preferences": me.get("match_preferences"),
        "candidate_circles": candidate_circles,
    }


@router.get("/invitations")
async def list_my_invitations(user_id: CurrentUserId) -> list[dict[str, Any]]:
    """Pods this user has been invited to but not yet accepted/declined."""
    sb = get_supabase()
    rows = (
        sb.table("members")
        .select(
            "group_id,status,invited_at,"
            "groups(id,name,status,contribution_amount_cents,cycle_count,"
            "theme,description,min_trust_score,accept_deadline)"
        )
        .eq("user_id", str(user_id))
        .eq("status", "invited")
        .execute()
    )
    out: list[dict[str, Any]] = []
    for r in rows.data or []:
        g = r.get("groups") or {}
        out.append(
            {
                **g,
                "member_status": r["status"],
                "invited_at": r.get("invited_at"),
                "accept_deadline": g.get("accept_deadline"),
            }
        )
    return out


@router.get("/accounts")
async def list_accounts(user_id: CurrentUserId) -> list[dict[str, Any]]:
    sb = get_supabase()
    label = await _bunq_label_for(sb, user_id)
    client = get_bunq_client(label)
    raw = await client.list_monetary_accounts()
    out: list[dict[str, Any]] = []
    for idx, a in enumerate(raw):
        if a.get("status") not in ("ACTIVE", "INACTIVE"):
            continue
        balance = a.get("balance") or {}
        iban = next(
            (al.get("value") for al in (a.get("alias") or []) if al.get("type") == "IBAN"),
            None,
        )
        # bunq has an avatar style we can use for a subtle card gradient hint,
        # but for consistency we rotate through a palette by account index.
        out.append(
            {
                "id": a.get("id"),
                "description": a.get("description"),
                "status": a.get("status"),
                "balance_cents": round(float(balance.get("value", 0)) * 100),
                "currency": balance.get("currency", "EUR"),
                "iban": iban,
                "type": a.get("type") or "MonetaryAccountBank",
                "palette_index": idx,
            }
        )
    return out


@router.get("/transactions")
async def list_transactions(
    user_id: CurrentUserId,
    account_id: int | None = Query(None),
    days: int = Query(7, ge=1, le=90),
    count: int = Query(60, ge=1, le=200),
) -> list[dict[str, Any]]:
    sb = get_supabase()
    label = await _bunq_label_for(sb, user_id)
    client = get_bunq_client(label)
    if account_id is None:
        account_id = await client.get_primary_account_id()
    raw = await client.list_payments(account_id=account_id, count=count)

    cutoff = datetime.now(timezone.utc) - timedelta(days=days)
    out: list[dict[str, Any]] = []
    for p in raw:
        created = p.get("created") or ""
        dt: datetime | None = None
        try:
            # bunq returns "2026-04-25 04:00:00.000000" with no tz.
            dt = datetime.fromisoformat(created.replace(" ", "T"))
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
        except Exception:  # noqa: BLE001
            dt = None
        if dt and dt < cutoff:
            continue
        amt = p.get("amount") or {}
        amt_cents = round(float(amt.get("value", 0)) * 100)
        counter = p.get("counterparty_alias") or {}
        out.append(
            {
                "id": p.get("id"),
                "created": created,
                "amount_cents": amt_cents,
                "currency": amt.get("currency", "EUR"),
                "description": p.get("description"),
                "counterparty_name": counter.get("display_name")
                or counter.get("label_monetary_account_name")
                or "",
                "counterparty_iban": counter.get("iban")
                if isinstance(counter.get("iban"), str)
                else None,
                "type": p.get("type"),
                "sub_type": p.get("sub_type"),
            }
        )
    return out
