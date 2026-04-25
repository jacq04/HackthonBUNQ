"""One-off: create a handful of admin-opened demo circles with no members.

These show up on the wallet's "your circles" / Matchmaker as already-open
templates the agent can fill from the waitlist.

Run from `backend/`:
    .venv/bin/python -m scripts.bootstrap_demo_circles
"""
from __future__ import annotations

import asyncio
import math
import uuid as uuid_mod
from datetime import datetime, timedelta, timezone

from app.bunq import get_bunq_client
from app.config import settings
from app.db import get_supabase
from app.ledger import create_group_accounts


DEMO_CIRCLES = [
    {
        "name": "Lagos Crew",
        "theme": "small business",
        "description": "6 traders saving for restock — Lagos market vendors.",
        "cultural_hint": "Nigerian / Yoruba",
        "contribution_amount_cents": 25000,
        "cycle_count": 6,
        "min_trust_score": 55,
        "payout_strategy": "rotation",
        "debit_day": 1,
    },
    {
        "name": "Berlin Builders",
        "theme": "tuition",
        "description": "8-month rotation for grad-student tuition top-ups.",
        "cultural_hint": "International students, Berlin",
        "contribution_amount_cents": 50000,
        "cycle_count": 8,
        "min_trust_score": 65,
        "payout_strategy": "bidding",
        "debit_day": 28,
    },
    {
        "name": "Amsterdam Anchors",
        "theme": "emergency fund",
        "description": "12 friends building a rotating safety net of €100/mo.",
        "cultural_hint": None,
        "contribution_amount_cents": 10000,
        "cycle_count": 12,
        "min_trust_score": 40,
        "payout_strategy": "rotation",
        "debit_day": 5,
    },
    {
        "name": "Mumbai Makers",
        "theme": "wedding",
        "description": "6-cycle pot for weddings — €350/mo each.",
        "cultural_hint": "Mumbai diaspora",
        "contribution_amount_cents": 35000,
        "cycle_count": 6,
        "min_trust_score": 60,
        "payout_strategy": "hybrid",
        "debit_day": 15,
    },
    {
        "name": "Lisbon Light",
        "theme": "moving expenses",
        "description": "4-cycle short rotation for relocation costs.",
        "cultural_hint": "Portuguese / Brazilian",
        "contribution_amount_cents": 75000,
        "cycle_count": 4,
        "min_trust_score": 70,
        "payout_strategy": "rotation",
        "debit_day": 1,
    },
]


async def _platform_bunq_account_id() -> str | None:
    try:
        client = get_bunq_client(settings.bunq_platform_label)
        await client.ensure_session()
        return str(await client.get_primary_account_id())
    except Exception as e:  # noqa: BLE001
        print(f"[demo] bunq account lookup failed: {e}")
        return None


def _admin_user_id(sb) -> str | None:
    r = (
        sb.table("users")
        .select("id")
        .eq("is_admin", True)
        .order("created_at")
        .limit(1)
        .execute()
    )
    rows = r.data or []
    return rows[0]["id"] if rows else None


async def main() -> None:
    sb = get_supabase()
    admin_id = _admin_user_id(sb)
    if not admin_id:
        print("[demo] no admin user — promote one first (asha)")
        return
    bunq_account = await _platform_bunq_account_id()
    print(f"[demo] platform bunq_account_id = {bunq_account}")

    # Skip circles whose names already exist (idempotent re-runs).
    existing = {
        r["name"]
        for r in (
            sb.table("groups").select("name").execute().data or []
        )
    }
    print(f"[demo] {len(existing)} existing circles, skipping by name")

    created: list[str] = []
    for spec in DEMO_CIRCLES:
        if spec["name"] in existing:
            print(f"[demo] skip {spec['name']} (already exists)")
            continue
        gid = uuid_mod.uuid4()
        tb_ids = create_group_accounts(gid, enforce_pool_invariant=True)
        invite_buffer = max(1, math.ceil(spec["cycle_count"] * 0.2))
        deadline = datetime.now(timezone.utc) + timedelta(hours=72)
        sb.table("groups").insert(
            {
                "id": str(gid),
                "name": spec["name"],
                "currency": "EUR",
                "contribution_amount_cents": spec["contribution_amount_cents"],
                "cycle_count": spec["cycle_count"],
                "grace_period_days": 3,
                "penalty_bps": 200,
                "tb_pool_account_id": tb_ids["pool"],
                "tb_gateway_account_id": tb_ids["gateway"],
                "tb_penalty_account_id": tb_ids["penalty"],
                "bunq_account_id": bunq_account,
                "status": "recruiting",
                "invite_buffer": invite_buffer,
                "accept_deadline": deadline.isoformat(),
                "debit_day": spec["debit_day"],
                "min_trust_score": spec["min_trust_score"],
                "max_members": spec["cycle_count"],
                "theme": spec["theme"],
                "cultural_hint": spec["cultural_hint"],
                "description": spec["description"],
                "payout_strategy": spec["payout_strategy"],
                "created_by": admin_id,
                "created_by_agent": None,
            }
        ).execute()
        sb.table("audit_log").insert(
            {
                "actor": f"user:{admin_id}",
                "action": "admin.circle.create",
                "resource_type": "group",
                "resource_id": str(gid),
                "diff": {**spec, "via": "bootstrap_demo_circles"},
            }
        ).execute()
        sb.table("events").insert(
            {
                "group_id": str(gid),
                "type": "admin.circle.opened",
                "payload": {
                    "by": admin_id,
                    "name": spec["name"],
                    "min_trust_score": spec["min_trust_score"],
                    "theme": spec["theme"],
                },
            }
        ).execute()
        created.append(spec["name"])
        print(f"[demo] opened circle {spec['name']!r} ({gid})")

    print(f"[demo] done — opened {len(created)} new circles")


if __name__ == "__main__":
    asyncio.run(main())
