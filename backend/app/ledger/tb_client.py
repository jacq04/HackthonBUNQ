"""TigerBeetle client wrapper.

Design:
  - Single shared client per process (TB is connection-pooled internally).
  - Account `code` field encodes account *type* (see AccountCode enum).
  - Account `user_data_128` carries the group_id bytes; `user_data_64` carries cycle_month.
  - All amounts are in cents (EUR minor units); ledger = 978 (ISO 4217 EUR).

The `tigerbeetle` Python client (v0.16+) is sync; we run calls in a thread
pool from async handlers via `asyncio.to_thread`.
"""
from __future__ import annotations

import enum
import uuid
from dataclasses import dataclass
from functools import lru_cache
from typing import Any

from app.config import settings
from app.utils.ids import uuid_to_tb_id

LEDGER_EUR = 978  # ISO 4217


class AccountCode(enum.IntEnum):
    """Account type codes. Stored in TigerBeetle's Account.code field."""

    GROUP_POOL = 100
    MEMBER_CONTRIB = 200
    MEMBER_RECEIVED = 201
    PENALTY_POOL = 300
    BUNQ_GATEWAY = 400


class TransferCode(enum.IntEnum):
    """Transfer type codes. Stored in TigerBeetle's Transfer.code field."""

    CONTRIBUTION = 1000
    PAYOUT = 1001
    PENALTY = 1002
    EMERGENCY_BUYOUT = 1003
    MEDIATOR_CORRECTION = 1004
    # Circle Lifecycle v2 — distinguish payout provenance at the ledger level
    # so the audit tape shows WHY money moved, not just that it did.
    BID_WON = 1010            # payout to the winning bidder of a cycle
    PAYOUT_FALLBACK = 1011    # 0-bid fallback — Payout Optimizer's scheduled slot winner
    MANDATE_FEE = 1020        # reserved (no-op in sandbox)


# TigerBeetle account/transfer flag bits (from the TB client library).
# These constants match the wire protocol regardless of SDK version.
FLAG_LINKED = 1 << 0
FLAG_DEBITS_MUST_NOT_EXCEED_CREDITS = 1 << 1
FLAG_CREDITS_MUST_NOT_EXCEED_DEBITS = 1 << 2

TRANSFER_FLAG_LINKED = 1 << 0
TRANSFER_FLAG_PENDING = 1 << 1
TRANSFER_FLAG_POST_PENDING_TRANSFER = 1 << 2
TRANSFER_FLAG_VOID_PENDING_TRANSFER = 1 << 3


@dataclass(frozen=True)
class AccountSpec:
    id: int
    code: AccountCode
    group_id: uuid.UUID
    flags: int = 0

    def user_data_128(self) -> int:
        return int.from_bytes(self.group_id.bytes, "big")


@lru_cache
def get_tb_client() -> Any:
    """Lazy singleton TB client. Import inside so module loads without the dep."""
    import tigerbeetle as tb  # type: ignore[import-not-found]

    # tigerbeetle-python expects a comma-separated string, not a list.
    addresses = ",".join(
        a.strip() for a in settings.tigerbeetle_addresses.split(",") if a.strip()
    )
    return tb.ClientSync(
        cluster_id=settings.tigerbeetle_cluster_id,
        replica_addresses=addresses,
    )


# -----------------------------------------------------------------------------
# Account helpers
# -----------------------------------------------------------------------------

def account_id_for(group_id: uuid.UUID | str, code: AccountCode, user_id: uuid.UUID | str | None = None) -> int:
    """Deterministic TB account id from (group, code, maybe-user)."""
    tag = f"{code.value}"
    if user_id is not None:
        if isinstance(user_id, str):
            user_id = uuid.UUID(user_id)
        tag += f":{user_id.hex}"
    return uuid_to_tb_id(group_id, tag=tag)


def create_group_accounts(group_id: uuid.UUID, *, enforce_pool_invariant: bool = True) -> dict[str, int]:
    """Create the four per-group accounts in one atomic batch.

    Returns a dict of role -> TB account id.
    """
    import tigerbeetle as tb  # type: ignore[import-not-found]

    group_ud128 = int.from_bytes(group_id.bytes, "big")

    accounts = [
        tb.Account(
            id=account_id_for(group_id, AccountCode.GROUP_POOL),
            user_data_128=group_ud128,
            user_data_64=0,
            user_data_32=0,
            ledger=LEDGER_EUR,
            code=AccountCode.GROUP_POOL,
            flags=FLAG_DEBITS_MUST_NOT_EXCEED_CREDITS if enforce_pool_invariant else 0,
        ),
        tb.Account(
            id=account_id_for(group_id, AccountCode.BUNQ_GATEWAY),
            user_data_128=group_ud128,
            user_data_64=0,
            user_data_32=0,
            ledger=LEDGER_EUR,
            code=AccountCode.BUNQ_GATEWAY,
            flags=0,
        ),
        tb.Account(
            id=account_id_for(group_id, AccountCode.PENALTY_POOL),
            user_data_128=group_ud128,
            user_data_64=0,
            user_data_32=0,
            ledger=LEDGER_EUR,
            code=AccountCode.PENALTY_POOL,
            flags=0,
        ),
    ]

    client = get_tb_client()
    errors = client.create_accounts(accounts)
    # TB returns errors only for failed indexes; existing-account is tolerable on re-runs.
    for err in errors:
        if str(err.result) not in ("exists", "exists_with_different_flags"):
            raise RuntimeError(f"TB create_accounts failed at index {err.index}: {err.result}")

    return {
        "pool": accounts[0].id,
        "gateway": accounts[1].id,
        "penalty": accounts[2].id,
    }


def create_member_accounts(group_id: uuid.UUID, user_id: uuid.UUID) -> dict[str, int]:
    """Create the two per-member accounts (contrib + received)."""
    import tigerbeetle as tb  # type: ignore[import-not-found]

    group_ud128 = int.from_bytes(group_id.bytes, "big")

    accounts = [
        tb.Account(
            id=account_id_for(group_id, AccountCode.MEMBER_CONTRIB, user_id),
            user_data_128=group_ud128,
            user_data_64=0,
            user_data_32=0,
            ledger=LEDGER_EUR,
            code=AccountCode.MEMBER_CONTRIB,
            flags=0,
        ),
        tb.Account(
            id=account_id_for(group_id, AccountCode.MEMBER_RECEIVED, user_id),
            user_data_128=group_ud128,
            user_data_64=0,
            user_data_32=0,
            ledger=LEDGER_EUR,
            code=AccountCode.MEMBER_RECEIVED,
            flags=0,
        ),
    ]

    client = get_tb_client()
    errors = client.create_accounts(accounts)
    for err in errors:
        if str(err.result) not in ("exists", "exists_with_different_flags"):
            raise RuntimeError(f"TB create_accounts failed at index {err.index}: {err.result}")

    return {
        "contrib": accounts[0].id,
        "received": accounts[1].id,
    }


def lookup_balance(account_id: int) -> dict[str, int]:
    """Fetch an account's balances. Returns {debits_posted, credits_posted, ..._pending}."""
    client = get_tb_client()
    results = client.lookup_accounts([account_id])
    if not results:
        raise LookupError(f"TB account {account_id} not found")
    a = results[0]
    return {
        "debits_posted": int(a.debits_posted),
        "credits_posted": int(a.credits_posted),
        "debits_pending": int(a.debits_pending),
        "credits_pending": int(a.credits_pending),
    }
