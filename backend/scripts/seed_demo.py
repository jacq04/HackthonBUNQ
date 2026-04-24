"""Seed a demo group with realistic history for on-stage rehearsal.

Usage:
    cd backend && python -m scripts.seed_demo

Creates "Lagos Crew" (6 members, €50/cycle, 3 months in), with contributions
already posted for months 1–3 and one live dispute + one pending emergency.
"""
from __future__ import annotations

import asyncio
import sys
import uuid

from app.agents.tools import emit_event
from app.db import get_supabase
from app.ledger.tb_client import (
    AccountCode,
    TransferCode,
    account_id_for,
    create_group_accounts,
    create_member_accounts,
)
from app.ledger.tb_two_phase import TransferLeg, linked_batch


DEMO_MEMBERS = [
    ("Aisha", "aisha@kitty.demo", "en"),
    ("Malik", "malik@kitty.demo", "en"),
    ("Priya", "priya@kitty.demo", "hi"),
    ("Tunde", "tunde@kitty.demo", "yo"),
    ("Fatou", "fatou@kitty.demo", "fr"),
    ("Raj",   "raj@kitty.demo", "hi"),
]


async def main() -> None:
    sb = get_supabase()

    group_id = uuid.uuid4()
    tb_ids = create_group_accounts(group_id, enforce_pool_invariant=True)

    member_records = []
    for name, email, lang in DEMO_MEMBERS:
        # Create auth.users rows via admin API — requires service role.
        user_id = uuid.uuid4()
        try:
            sb.auth.admin.create_user(
                {"email": email, "email_confirm": True, "user_metadata": {"demo": True}}
            )
            # Upsert profile.
            sb.table("users").upsert(
                {"id": str(user_id), "display_name": name, "language": lang}
            ).execute()
        except Exception as e:  # noqa: BLE001
            print(f"[seed] {name}: {e}")
        member_records.append({"id": user_id, "name": name, "email": email})

    sb.table("groups").insert(
        {
            "id": str(group_id),
            "name": "Lagos Crew",
            "contribution_amount_cents": 5000,
            "cycle_count": 6,
            "currency": "EUR",
            "grace_period_days": 3,
            "penalty_bps": 200,
            "tb_pool_account_id": tb_ids["pool"],
            "tb_gateway_account_id": tb_ids["gateway"],
            "tb_penalty_account_id": tb_ids["penalty"],
            "status": "active",
        }
    ).execute()

    for i, m in enumerate(member_records):
        ids = create_member_accounts(group_id, m["id"])
        sb.table("members").insert(
            {
                "group_id": str(group_id),
                "user_id": str(m["id"]),
                "role": "admin" if i == 0 else "member",
                "status": "active",
                "payout_cycle": i + 1,
                "tb_contrib_account_id": ids["contrib"],
                "tb_received_account_id": ids["received"],
            }
        ).execute()

    # Post 3 cycles' worth of contributions already.
    pool = tb_ids["pool"]
    gateway = tb_ids["gateway"]
    for cycle in (1, 2, 3):
        for m in member_records:
            member_contrib = account_id_for(group_id, AccountCode.MEMBER_CONTRIB, m["id"])
            linked_batch(
                [
                    TransferLeg(gateway, pool, 5000, TransferCode.CONTRIBUTION),
                    TransferLeg(gateway, member_contrib, 5000, TransferCode.CONTRIBUTION),
                ],
                group_id=group_id,
                cycle_month=cycle,
            )
            await emit_event(
                group_id,
                type="contribution.posted",
                payload={
                    "user_id": str(m["id"]),
                    "amount_cents": 5000,
                    "cycle_month": cycle,
                },
            )

    print(f"✓ seeded demo group {group_id}")
    print(f"  members: {[m['name'] for m in member_records]}")
    print(f"  pot balance ~ €{(5000 * len(member_records) * 3) / 100:.2f}")


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except Exception as e:
        print(f"[seed] fatal: {e}", file=sys.stderr)
        sys.exit(1)
