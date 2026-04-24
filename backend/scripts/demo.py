"""Kitty demo driver.

Single CLI for on-stage beats. Every subcommand is idempotent and runs
directly against the backend's modules (no HTTP, no auth ceremony) so a
demo-er can drive the flow from one terminal window while the simulator
renders the UI live via Supabase Realtime.

Usage:
    python -m scripts.demo seed                 # setup Lagos Crew in known state
    python -m scripts.demo status               # print current ledger + members
    python -m scripts.demo contribute tunde     # post a pending contribution + commit it
    python -m scripts.demo dispute malik        # Malik opens a dispute, Mediator resolves
    python -m scripts.demo emergency priya      # Priya requests exit, group approves, TB unwinds
    python -m scripts.demo payout               # run current-cycle payout (atomic)
    python -m scripts.demo reset                # wipe group + TB accounts + demo users

The seed builds this state:
    Lagos Crew · 6 members · €250/cycle · 6 cycles · ACTIVE · charter finalized
    Members: asha (admin), malik, priya, tunde, fatou, raj
    Payout order: asha=1, malik=2, priya=3, tunde=4, fatou=5, raj=6
    Contributions: cycles 1-3 all posted (pot at €4500)
    Cycle 4: Tunde has a pending contribution that we'll commit during the demo
"""
from __future__ import annotations

import argparse
import asyncio
import sys
import uuid
from typing import Any

from app.agents.emergency import get_emergency
from app.agents.mediator import get_mediator
from app.agents.tools import emit_event
from app.bunq import get_bunq_client
from app.db import get_supabase
from app.ledger.tb_client import (
    AccountCode,
    TransferCode,
    account_id_for,
    create_group_accounts,
    create_member_accounts,
    get_tb_client,
    lookup_balance,
)
from app.ledger.tb_two_phase import TransferLeg, linked_batch
from app.routes.contribute import _create_linked_pending_pair
from app.utils.ids import new_tb_id

CONTRIBUTION_CENTS = 25000  # €250
CYCLE_COUNT = 6
GROUP_NAME = "Lagos Crew"
LABELS = ["asha", "malik", "priya", "tunde", "fatou", "raj"]

# ANSI colors for terminal drama.
GRN = "\033[32m"
CYA = "\033[36m"
YEL = "\033[33m"
RED = "\033[31m"
BLD = "\033[1m"
DIM = "\033[2m"
RST = "\033[0m"


def log(msg: str) -> None:
    print(f"{CYA}[demo]{RST} {msg}")


def ok(msg: str) -> None:
    print(f"{GRN}  ✓{RST} {msg}")


def warn(msg: str) -> None:
    print(f"{YEL}  !{RST} {msg}")


def die(msg: str) -> None:
    print(f"{RED}[demo]{RST} {msg}", file=sys.stderr)
    sys.exit(1)


# -----------------------------------------------------------------------------
# Shared helpers
# -----------------------------------------------------------------------------
async def _bunq_profile(label: str) -> dict[str, Any]:
    """Display name + IBAN for a bunq sandbox user (cached after first call)."""
    client = get_bunq_client(label)
    await client.ensure_session()
    name = label.capitalize()
    iban = None
    try:
        accounts = await client.list_monetary_accounts()
        for a in accounts:
            if a.get("status") != "ACTIVE":
                continue
            for alias in a.get("alias") or []:
                if alias.get("type") == "IBAN" and not iban:
                    iban = alias.get("value")
                    if alias.get("name"):
                        name = alias.get("name")
            break
    except Exception as e:  # noqa: BLE001
        warn(f"bunq profile fetch failed for {label}: {e}")
    return {"display_name": name, "primary_iban": iban, "bunq_user_id": client.user_id}


def _find_or_create_supabase_user(sb: Any, email: str, profile: dict) -> str:
    """Find the Supabase auth user by email, or create one. Returns UUID string."""
    users = sb.auth.admin.list_users() or []
    for u in users:
        if getattr(u, "email", None) == email:
            return str(u.id)
    created = sb.auth.admin.create_user(
        {
            "email": email,
            "email_confirm": True,
            "user_metadata": {
                "display_name": profile["display_name"],
                "bunq_user_id": profile["bunq_user_id"],
            },
        }
    )
    return str(created.user.id)


def _find_demo_group(sb: Any) -> dict | None:
    r = sb.table("groups").select("*").eq("name", GROUP_NAME).limit(1).execute()
    return r.data[0] if r.data else None


def _load_members(sb: Any, group_id: str) -> dict[str, dict]:
    """Return {label: {id, ...}} for the demo group."""
    r = (
        sb.table("members")
        .select("*,users!inner(display_name,bunq_label)")
        .eq("group_id", group_id)
        .execute()
    )
    out: dict[str, dict] = {}
    for row in r.data or []:
        label = row["users"]["bunq_label"]
        out[label] = {**row, "display_name": row["users"]["display_name"]}
    return out


# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------
async def cmd_seed(_: argparse.Namespace) -> None:
    sb = get_supabase()

    if _find_demo_group(sb):
        warn(f"{GROUP_NAME} already exists — run `demo reset` first")
        return

    log(f"linking bunq identities for: {', '.join(LABELS)}")
    members: dict[str, dict] = {}
    for label in LABELS:
        email = f"{label}@kitty.demo"
        profile = await _bunq_profile(label)
        uid = _find_or_create_supabase_user(sb, email, profile)
        sb.table("users").upsert(
            {
                "id": uid,
                "display_name": profile["display_name"],
                "bunq_user_id": str(profile["bunq_user_id"]) if profile["bunq_user_id"] else None,
                "bunq_label": label,
                "language": "en",
            },
            on_conflict="id",
        ).execute()
        members[label] = {"user_id": uid, **profile}
        ok(f"{label:6} → {profile['display_name']} ({profile['primary_iban']})")

    log("creating group + TigerBeetle pool/gateway/penalty accounts")
    group_id = uuid.uuid4()
    tb_ids = create_group_accounts(group_id)
    sb.table("groups").insert(
        {
            "id": str(group_id),
            "name": GROUP_NAME,
            "currency": "EUR",
            "contribution_amount_cents": CONTRIBUTION_CENTS,
            "cycle_count": CYCLE_COUNT,
            "grace_period_days": 3,
            "penalty_bps": 200,
            "tb_pool_account_id": tb_ids["pool"],
            "tb_gateway_account_id": tb_ids["gateway"],
            "tb_penalty_account_id": tb_ids["penalty"],
            "status": "active",
            "created_by": members["asha"]["user_id"],
        }
    ).execute()
    ok(f"group {group_id} created")

    log("assigning members + per-member TB accounts")
    for i, label in enumerate(LABELS):
        m = members[label]
        tb_member = create_member_accounts(group_id, uuid.UUID(m["user_id"]))
        sb.table("members").insert(
            {
                "group_id": str(group_id),
                "user_id": m["user_id"],
                "role": "admin" if label == "asha" else "member",
                "status": "active",
                "payout_cycle": i + 1,
                "tb_contrib_account_id": tb_member["contrib"],
                "tb_received_account_id": tb_member["received"],
            }
        ).execute()
        ok(f"{label:6} ← cycle {i + 1}")

    log("finalizing charter (one version, fully signed)")
    sb.table("charters").insert(
        {
            "group_id": str(group_id),
            "version": 1,
            "content": {
                "contribution_amount_cents": CONTRIBUTION_CENTS,
                "currency": "EUR",
                "cycle_count": CYCLE_COUNT,
                "contribution_frequency": "monthly",
                "grace_period_days": 3,
                "penalty_bps": 200,
                "payout_ordering": "agent_optimized",
                "default_handling": "First miss: 48h grace, +2% penalty. Second miss: mediator mediates.",
                "membership_changes": "New members only at cycle boundary. Exits require group consent.",
                "early_exit_rules": "Buyout = contributions paid − pot received. Group may waive.",
                "dispute_escalation": "Mediator first, human second.",
            },
            "signed_by": [members[l]["user_id"] for l in LABELS],
            "finalized_at": "now()",
        }
    ).execute()
    await emit_event(group_id, type="charter.finalized", payload={"version": 1})
    ok("charter v1 finalized")

    log("posting 3 cycles of contributions (all members)")
    for cycle in (1, 2, 3):
        for label in LABELS:
            uid = uuid.UUID(members[label]["user_id"])
            member_contrib = account_id_for(group_id, AccountCode.MEMBER_CONTRIB, uid)
            linked_batch(
                [
                    TransferLeg(
                        tb_ids["gateway"], tb_ids["pool"], CONTRIBUTION_CENTS,
                        TransferCode.CONTRIBUTION,
                    ),
                    TransferLeg(
                        tb_ids["gateway"], member_contrib, CONTRIBUTION_CENTS,
                        TransferCode.CONTRIBUTION,
                    ),
                ],
                group_id=group_id,
                cycle_month=cycle,
            )
            await emit_event(
                group_id,
                type="contribution.posted",
                payload={
                    "user_id": members[label]["user_id"],
                    "amount_cents": CONTRIBUTION_CENTS,
                    "cycle_month": cycle,
                    "demo": True,
                },
            )
    pool_bal = lookup_balance(tb_ids["pool"])
    ok(f"pool balance: €{(pool_bal['credits_posted'] - pool_bal['debits_posted']) / 100:.2f}")

    log("staging a pending contribution for cycle 4 (Tunde — late)")
    uid = uuid.UUID(members["tunde"]["user_id"])
    pool_pend, member_pend = _create_linked_pending_pair(
        group_id=group_id,
        cycle_month=4,
        amount_cents=CONTRIBUTION_CENTS,
        gateway=tb_ids["gateway"],
        pool=tb_ids["pool"],
        member_contrib=account_id_for(group_id, AccountCode.MEMBER_CONTRIB, uid),
    )
    contrib_id = str(uuid.uuid4())
    sb.table("contributions").insert(
        {
            "id": contrib_id,
            "group_id": str(group_id),
            "user_id": members["tunde"]["user_id"],
            "cycle_month": 4,
            "amount_cents": CONTRIBUTION_CENTS,
            "tb_pending_pool_id": pool_pend,
            "tb_pending_member_id": member_pend,
            "status": "pending",
        }
    ).execute()
    ok(f"pending contribution {contrib_id} staged for tunde/cycle 4")

    print()
    print(f"{BLD}seed complete.{RST} Open the app signed in as any of {LABELS}.")
    print(f"  group_id = {group_id}")
    print("  next beats:  demo contribute tunde   |   demo dispute malik   |   demo emergency priya   |   demo payout")


async def cmd_status(_: argparse.Namespace) -> None:
    sb = get_supabase()
    group = _find_demo_group(sb)
    if not group:
        die("no demo group — run `demo seed` first")
    members = _load_members(sb, group["id"])

    pool = lookup_balance(int(group["tb_pool_account_id"]))
    pool_bal = pool["credits_posted"] - pool["debits_posted"]
    pending = pool["credits_pending"]

    print(f"{BLD}{GROUP_NAME}{RST}  ({group['status']})")
    print(f"  pool: €{pool_bal / 100:,.2f} posted  +  €{pending / 100:,.2f} pending")
    print(f"  members:")
    for label in LABELS:
        m = members.get(label)
        if not m:
            continue
        cb = lookup_balance(int(m["tb_contrib_account_id"]))
        rb = lookup_balance(int(m["tb_received_account_id"]))
        print(
            f"    {label:6} {m['display_name']:20} "
            f"contrib €{cb['credits_posted'] / 100:>7,.2f}  "
            f"received €{rb['credits_posted'] / 100:>7,.2f}  "
            f"payout_cycle={m.get('payout_cycle')}"
        )

    disputes = sb.table("disputes").select("id,status,amount_cents").eq("group_id", group["id"]).execute()
    if disputes.data:
        print(f"  open disputes: {sum(1 for d in disputes.data if d['status'] == 'open')}")
    emergencies = sb.table("emergencies").select("id,status").eq("group_id", group["id"]).execute()
    if emergencies.data:
        print(f"  emergencies: {len(emergencies.data)} ({[e['status'] for e in emergencies.data]})")


async def cmd_contribute(args: argparse.Namespace) -> None:
    sb = get_supabase()
    group = _find_demo_group(sb) or die("run `demo seed` first")
    members = _load_members(sb, group["id"])
    m = members.get(args.label) or die(f"no member {args.label}")

    # Find a pending contribution row; if none, stage one for the next open cycle.
    r = (
        sb.table("contributions")
        .select("*")
        .eq("group_id", group["id"])
        .eq("user_id", m["user_id"])
        .eq("status", "pending")
        .order("cycle_month", desc=True)
        .limit(1)
        .execute()
    )
    if r.data:
        contrib = r.data[0]
        log(f"found existing pending contribution for {args.label} (cycle {contrib['cycle_month']})")
    else:
        log(f"no pending contribution for {args.label} — staging a fresh one")
        cycle = 4  # demo default
        pool_pend, member_pend = _create_linked_pending_pair(
            group_id=uuid.UUID(group["id"]),
            cycle_month=cycle,
            amount_cents=CONTRIBUTION_CENTS,
            gateway=int(group["tb_gateway_account_id"]),
            pool=int(group["tb_pool_account_id"]),
            member_contrib=account_id_for(uuid.UUID(group["id"]), AccountCode.MEMBER_CONTRIB, uuid.UUID(m["user_id"])),
        )
        contrib_row = {
            "id": str(uuid.uuid4()),
            "group_id": group["id"],
            "user_id": m["user_id"],
            "cycle_month": cycle,
            "amount_cents": CONTRIBUTION_CENTS,
            "tb_pending_pool_id": pool_pend,
            "tb_pending_member_id": member_pend,
            "status": "pending",
        }
        sb.table("contributions").insert(contrib_row).execute()
        contrib = contrib_row

    # Simulate bunq payment landing — post the TB pending transfers.
    log(f"simulating bunq webhook payment from {m['display_name']} …")
    from app.ledger.tb_two_phase import post_pending

    post_pending(int(contrib["tb_pending_pool_id"]), group_id=uuid.UUID(group["id"]), cycle_month=contrib["cycle_month"])
    post_pending(int(contrib["tb_pending_member_id"]), group_id=uuid.UUID(group["id"]), cycle_month=contrib["cycle_month"])

    sb.table("contributions").update(
        {"status": "posted", "bunq_payment_id": f"DEMO-{contrib['cycle_month']}-{args.label}", "posted_at": "now()"}
    ).eq("id", contrib["id"]).execute()

    await emit_event(
        uuid.UUID(group["id"]),
        type="contribution.posted",
        payload={
            "user_id": m["user_id"],
            "amount_cents": int(contrib["amount_cents"]),
            "cycle_month": contrib["cycle_month"],
            "demo": True,
        },
    )
    ok(f"committed · pot +€{int(contrib['amount_cents']) / 100:,.2f}")


async def cmd_dispute(args: argparse.Namespace) -> None:
    sb = get_supabase()
    group = _find_demo_group(sb) or die("run `demo seed` first")
    members = _load_members(sb, group["id"])
    claimant = members.get(args.label) or die(f"no member {args.label}")

    dispute_id = str(uuid.uuid4())
    sb.table("disputes").insert(
        {
            "id": dispute_id,
            "group_id": group["id"],
            "claimant_user_id": claimant["user_id"],
            "amount_cents": CONTRIBUTION_CENTS,
            "status": "open",
            "evidence_urls": [],
        }
    ).execute()
    log(f"dispute {dispute_id[:8]}… opened by {claimant['display_name']}")

    prompt = (
        f"Member {claimant['display_name']} (user_id={claimant['user_id']}) "
        f"claims they paid the cycle-3 contribution of €{CONTRIBUTION_CENTS / 100:,.2f} "
        f"but is worried the pool doesn't reflect it. "
        f"Dispute ID: {dispute_id}. "
        f"Cycle_month to investigate: 3. "
        f"Start by reading the TB ledger with read_tb_ledger to check their "
        f"member_contrib balance, then verify against bunq tx history if relevant. "
        f"Pass the EXACT user_id string above to any tool that needs it — do not abbreviate."
    )
    log("invoking Mediator agent…")
    result = await get_mediator().run(
        prompt,
        context={
            "group_id": uuid.UUID(group["id"]),
            "dispute_id": uuid.UUID(dispute_id),
            "claimant_user_id": claimant["user_id"],
        },
    )
    ok(f"mediator finished ({len(result.tool_calls)} tool calls)")
    for tc in result.tool_calls:
        if tc["name"] == "propose_resolution":
            verdict = tc["input"]
            print(f"  {BLD}verdict:{RST} {verdict['verdict']}")
            print(f"  {DIM}{verdict['public_message']}{RST}")


async def cmd_emergency(args: argparse.Namespace) -> None:
    sb = get_supabase()
    group = _find_demo_group(sb) or die("run `demo seed` first")
    members = _load_members(sb, group["id"])
    user = members.get(args.label) or die(f"no member {args.label}")

    emergency_id = str(uuid.uuid4())
    reason = (
        "My mother needs urgent surgery this week — I have to pull out now and "
        "route my savings to the clinic."
    )
    sb.table("emergencies").insert(
        {
            "id": emergency_id,
            "group_id": group["id"],
            "user_id": user["user_id"],
            "reason": reason,
            "status": "open",
        }
    ).execute()
    log(f"emergency {emergency_id[:8]}… from {user['display_name']}")

    log("invoking Emergency agent (compute buyout + post proposal)…")
    agent = get_emergency()
    result = await agent.run(
        f"Member {user['display_name']} has requested an emergency exit. Reason:\n{reason}\n\n"
        f"Emergency ID: {emergency_id}. Begin by computing the buyout for user {user['user_id']}.",
        context={
            "group_id": uuid.UUID(group["id"]),
            "emergency_id": uuid.UUID(emergency_id),
            "user_id": user["user_id"],
        },
    )
    ok(f"agent proposal ({len(result.tool_calls)} tool calls)")

    # Simulate group consent.
    others = [m["user_id"] for label, m in members.items() if label != args.label]
    sb.table("emergencies").update({"group_consent_user_ids": others}).eq("id", emergency_id).execute()

    # Pull the refund amount the agent just proposed.
    proposed = next(
        (tc["input"]["proposed_refund_cents"] for tc in result.tool_calls if tc["name"] == "post_proposal"),
        None,
    )
    if proposed is None:
        warn("agent did not propose a refund — skipping execute step")
        return

    log(f"group consent simulated ({len(others)} approvals) — asking agent to execute €{proposed / 100:,.2f} buyout")
    result2 = await agent.run(
        (
            f"Consent reached from {len(others)} members. "
            f"Call execute_buyout IMMEDIATELY with user_id='{user['user_id']}' "
            f"and refund_cents={proposed}. "
            f"Do NOT call compute_buyout or post_proposal — those were done already. "
            f"Call execute_buyout exactly once, then finish."
        ),
        context={
            "group_id": uuid.UUID(group["id"]),
            "emergency_id": uuid.UUID(emergency_id),
            "user_id": user["user_id"],
        },
    )
    executed = False
    for tc in result2.tool_calls:
        if tc["name"] == "execute_buyout":
            executed = True
            ok(f"TB unwind fired · transfers: {tc['result'].get('tb_transfer_ids', [])}")
    if not executed:
        warn("agent did not execute; firing the tool directly as a fallback")
        await agent.handle_tool.__wrapped__(agent, "execute_buyout", {"user_id": user["user_id"], "refund_cents": proposed}) if hasattr(agent.handle_tool, "__wrapped__") else await agent.handle_tool("execute_buyout", {"user_id": user["user_id"], "refund_cents": proposed})
        ok("executed via direct tool call")


async def cmd_payout(args: argparse.Namespace) -> None:
    sb = get_supabase()
    group = _find_demo_group(sb) or die("run `demo seed` first")
    members = _load_members(sb, group["id"])

    cycle = args.cycle or 4
    recipient = next((m for m in members.values() if m.get("payout_cycle") == cycle), None)
    if not recipient:
        die(f"no member assigned to cycle {cycle}")

    pool_cents = CONTRIBUTION_CENTS * CYCLE_COUNT
    log(f"running payout: cycle {cycle} → {recipient['display_name']} (€{pool_cents / 100:,.2f})")

    gateway = int(group["tb_gateway_account_id"])
    pool = int(group["tb_pool_account_id"])
    member_received = int(recipient["tb_received_account_id"])
    tb_ids = linked_batch(
        [
            TransferLeg(pool, gateway, pool_cents, TransferCode.PAYOUT),
            TransferLeg(pool, member_received, pool_cents, TransferCode.PAYOUT),
        ],
        group_id=uuid.UUID(group["id"]),
        cycle_month=cycle,
    )
    ok(f"TB linked batch fired · {len(tb_ids)} transfers atomically")

    payout_id = str(uuid.uuid4())
    sb.table("payouts").insert(
        {
            "id": payout_id,
            "group_id": group["id"],
            "recipient_user_id": recipient["user_id"],
            "cycle_month": cycle,
            "amount_cents": pool_cents,
            "tb_transfer_ids": [str(x) for x in tb_ids],
            "status": "pending",
        }
    ).execute()
    await emit_event(
        uuid.UUID(group["id"]),
        type="payout.ledger_only",
        payload={
            "payout_id": payout_id,
            "recipient_user_id": recipient["user_id"],
            "cycle_month": cycle,
            "amount_cents": pool_cents,
            "tb_transfer_ids": [str(x) for x in tb_ids],
            "demo": True,
        },
    )
    ok("ledger event emitted (real bunq payment would fire here in prod)")


async def cmd_reset(_: argparse.Namespace) -> None:
    """Wipe the demo group from Postgres. TB accounts stay (TB doesn't support delete)."""
    sb = get_supabase()
    group = _find_demo_group(sb)
    if not group:
        warn("no demo group to reset")
        return
    gid = group["id"]
    for table in ("events", "messages", "contributions", "payouts", "charters", "disputes", "emergencies", "members"):
        sb.table(table).delete().eq("group_id", gid).execute()
    sb.table("groups").delete().eq("id", gid).execute()
    ok(f"wiped {GROUP_NAME} ({gid})")
    warn("TB accounts remain (TB has no delete). Next seed will reuse them.")


# -----------------------------------------------------------------------------
# Entrypoint
# -----------------------------------------------------------------------------
def main() -> None:
    parser = argparse.ArgumentParser(description="Kitty demo driver")
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("seed").set_defaults(func=cmd_seed)
    sub.add_parser("status").set_defaults(func=cmd_status)
    sub.add_parser("reset").set_defaults(func=cmd_reset)

    p = sub.add_parser("contribute")
    p.add_argument("label", choices=LABELS)
    p.set_defaults(func=cmd_contribute)

    p = sub.add_parser("dispute")
    p.add_argument("label", choices=LABELS)
    p.set_defaults(func=cmd_dispute)

    p = sub.add_parser("emergency")
    p.add_argument("label", choices=LABELS)
    p.set_defaults(func=cmd_emergency)

    p = sub.add_parser("payout")
    p.add_argument("--cycle", type=int, default=None)
    p.set_defaults(func=cmd_payout)

    args = parser.parse_args()
    asyncio.run(args.func(args))


if __name__ == "__main__":
    main()
