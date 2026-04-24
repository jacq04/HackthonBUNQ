"""Two-phase transfer helpers.

Contribution flow (canonical two-phase):
    1. create_pending(amount, from=gateway, to=pool)  -> pending_id
    2. bunq webhook confirms the real payment
    3. post_pending(pending_id)                       -> transfer commits
    (or) void_pending(pending_id)                     -> transfer unwinds

Payout / emergency buyout use LINKED batches (atomic multi-leg), not two-phase.
"""
from __future__ import annotations

import uuid
from dataclasses import dataclass

from app.ledger.tb_client import (
    LEDGER_EUR,
    TRANSFER_FLAG_LINKED,
    TRANSFER_FLAG_PENDING,
    TRANSFER_FLAG_POST_PENDING_TRANSFER,
    TRANSFER_FLAG_VOID_PENDING_TRANSFER,
    TransferCode,
    get_tb_client,
)
from app.utils.ids import new_tb_id

# Sentinel: on a POST_PENDING_TRANSFER, amount=AMOUNT_MAX means "post the full
# pending amount." amount=0 means "post zero, void the rest" (surprising default
# — cost us an hour). amount ∈ (0, pending.amount) is a partial post.
AMOUNT_MAX = (1 << 128) - 1


@dataclass(frozen=True)
class TransferLeg:
    debit_account_id: int
    credit_account_id: int
    amount_cents: int
    code: TransferCode


def _raise_if_failed(errors: list) -> None:
    """Allow only benign results; anything else aborts."""
    benign = {"ok", "exists"}
    for err in errors:
        result = str(err.result)
        if result not in benign:
            raise RuntimeError(f"TB transfer failed at index {err.index}: {result}")


def create_pending(
    *,
    leg: TransferLeg,
    group_id: uuid.UUID,
    cycle_month: int = 0,
) -> int:
    """Create a single PENDING transfer. Returns the transfer id."""
    import tigerbeetle as tb  # type: ignore[import-not-found]

    t_id = new_tb_id()
    transfer = tb.Transfer(
        id=t_id,
        debit_account_id=leg.debit_account_id,
        credit_account_id=leg.credit_account_id,
        amount=leg.amount_cents,
        pending_id=0,
        user_data_128=int.from_bytes(group_id.bytes, "big"),
        user_data_64=cycle_month,
        user_data_32=0,
        timeout=0,
        ledger=LEDGER_EUR,
        code=leg.code,
        flags=TRANSFER_FLAG_PENDING,
    )

    client = get_tb_client()
    errors = client.create_transfers([transfer])
    _raise_if_failed(errors)
    return t_id


def post_pending(pending_id: int, *, group_id: uuid.UUID, cycle_month: int = 0) -> int:
    """Commit (post) an earlier PENDING transfer. Returns the post's transfer id."""
    import tigerbeetle as tb  # type: ignore[import-not-found]

    t_id = new_tb_id()
    transfer = tb.Transfer(
        id=t_id,
        debit_account_id=0,  # inherited from pending
        credit_account_id=0,
        amount=AMOUNT_MAX,  # = post the full pending amount (NOT 0 — that voids!)
        pending_id=pending_id,
        user_data_128=int.from_bytes(group_id.bytes, "big"),
        user_data_64=cycle_month,
        user_data_32=0,
        timeout=0,
        ledger=0,
        code=0,
        flags=TRANSFER_FLAG_POST_PENDING_TRANSFER,
    )

    client = get_tb_client()
    errors = client.create_transfers([transfer])
    _raise_if_failed(errors)
    return t_id


def void_pending(pending_id: int, *, group_id: uuid.UUID, cycle_month: int = 0) -> int:
    """Unwind a PENDING transfer (e.g. bunq payment failed)."""
    import tigerbeetle as tb  # type: ignore[import-not-found]

    t_id = new_tb_id()
    transfer = tb.Transfer(
        id=t_id,
        debit_account_id=0,
        credit_account_id=0,
        amount=0,
        pending_id=pending_id,
        user_data_128=int.from_bytes(group_id.bytes, "big"),
        user_data_64=cycle_month,
        user_data_32=0,
        timeout=0,
        ledger=0,
        code=0,
        flags=TRANSFER_FLAG_VOID_PENDING_TRANSFER,
    )

    client = get_tb_client()
    errors = client.create_transfers([transfer])
    _raise_if_failed(errors)
    return t_id


def linked_batch(legs: list[TransferLeg], *, group_id: uuid.UUID, cycle_month: int = 0) -> list[int]:
    """Execute multiple transfers as a single atomic batch (payout, buyout unwind).

    All legs except the last carry the LINKED flag; if any leg fails, the entire
    chain rolls back.
    """
    import tigerbeetle as tb  # type: ignore[import-not-found]

    if not legs:
        return []

    group_ud128 = int.from_bytes(group_id.bytes, "big")
    transfers = []
    for i, leg in enumerate(legs):
        flags = TRANSFER_FLAG_LINKED if i < len(legs) - 1 else 0
        transfers.append(
            tb.Transfer(
                id=new_tb_id(),
                debit_account_id=leg.debit_account_id,
                credit_account_id=leg.credit_account_id,
                amount=leg.amount_cents,
                pending_id=0,
                user_data_128=group_ud128,
                user_data_64=cycle_month,
                user_data_32=0,
                timeout=0,
                ledger=LEDGER_EUR,
                code=leg.code,
                flags=flags,
            )
        )

    client = get_tb_client()
    errors = client.create_transfers(transfers)
    _raise_if_failed(errors)
    return [t.id for t in transfers]
