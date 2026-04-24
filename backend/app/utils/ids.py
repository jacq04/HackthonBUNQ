"""ID helpers.

TigerBeetle account and transfer IDs are uint128. We derive deterministic IDs
from UUIDs so Postgres and TB stay in sync without a second mapping table.
"""
from __future__ import annotations

import hashlib
import uuid

UINT128_MAX = (1 << 128) - 1


def uuid_to_tb_id(u: uuid.UUID | str, tag: str = "") -> int:
    """Map a UUID to a TigerBeetle uint128 id.

    Mixes in an optional tag so the same UUID can produce distinct account ids
    (e.g. pool vs gateway vs penalty for the same group).
    """
    if isinstance(u, str):
        u = uuid.UUID(u)
    digest = hashlib.blake2b(u.bytes + tag.encode(), digest_size=16).digest()
    return int.from_bytes(digest, "big") & UINT128_MAX


def new_tb_id() -> int:
    """Random uint128 for transfer ids."""
    return int.from_bytes(uuid.uuid4().bytes, "big")
