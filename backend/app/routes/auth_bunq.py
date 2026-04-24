"""Sign in with bunq.

Sandbox-friendly equivalent of "Sign in with Google/Apple". The bunq sandbox
doesn't host a proper OAuth 2.0 server for 3rd-party apps, so we reuse the
already-bootstrapped sandbox user contexts (one file per label at
~/.kitty/bunq-contexts/<label>.json, see scripts/bunq_bootstrap.py).

Flow:
    GET  /auth/bunq/users            → list candidate bunq labels (display name + IBAN)
    POST /auth/bunq                  → pick a label; mint a Supabase OTP bound to
                                        the matching email; return {email, otp}
    client: supabase.auth.verifyOtp({ email, token, type: 'email' })

Result: the Kitty user is signed in via Supabase, `public.users.bunq_label`
stores which bunq identity they own, and any downstream route can act on
their behalf via `get_bunq_client(user.bunq_label)`.

Production swap: replace the picker with bunq OAuth 2.0 (Authorization Code
+ PKCE), exchange the code for a bunq API key, then drop the key into the
same cached-context format — the rest of this flow is identical.
"""
from __future__ import annotations

import os
from pathlib import Path
from typing import Any

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel

from app.bunq import get_bunq_client
from app.config import settings
from app.db import get_supabase
from app.utils.logging import get_logger

log = get_logger(__name__)
router = APIRouter(prefix="/auth/bunq", tags=["auth"])


# -----------------------------------------------------------------------------
# Models
# -----------------------------------------------------------------------------
class BunqUserCard(BaseModel):
    label: str
    display_name: str
    bunq_user_id: int | None = None
    primary_iban: str | None = None
    culture_hint: str | None = None


class BunqSigninRequest(BaseModel):
    label: str


class BunqSigninResponse(BaseModel):
    email: str
    otp: str
    expires_in: int


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
async def _bunq_profile(label: str) -> dict[str, Any]:
    """Pull the authoritative display_name from the bunq UserPerson object.

    Falls back to the IBAN alias's name, then to the label (worst case).
    The IBAN field is always taken from the primary ACTIVE account.
    """
    client = get_bunq_client(label)
    await client.ensure_session()

    display_name: str | None = None
    primary_iban: str | None = None

    try:
        accounts = await client.list_monetary_accounts()
        for a in accounts:
            if a.get("status") != "ACTIVE":
                continue
            for alias in a.get("alias") or []:
                if alias.get("type") == "IBAN" and not primary_iban:
                    primary_iban = alias.get("value")
                    if not display_name:
                        display_name = alias.get("name")
            break
    except Exception as e:  # noqa: BLE001
        log.warning("auth.bunq.profile.failed", label=label, error=str(e))

    # If we still don't have a name, fall back to label.
    if not display_name:
        display_name = label.capitalize()

    return {
        "bunq_user_id": client.user_id,
        "display_name": display_name,
        "primary_iban": primary_iban,
    }


# -----------------------------------------------------------------------------
# Routes
# -----------------------------------------------------------------------------
@router.get("/users", response_model=list[BunqUserCard])
async def list_bunq_users() -> list[BunqUserCard]:
    """List every bunq label with a cached session on this host."""
    ctx_dir = Path(os.path.expanduser(settings.bunq_context_dir))
    if not ctx_dir.exists():
        return []

    cards: list[BunqUserCard] = []
    for ctx_file in sorted(ctx_dir.glob("*.json")):
        label = ctx_file.stem
        try:
            profile = await _bunq_profile(label)
            cards.append(
                BunqUserCard(
                    label=label,
                    display_name=profile["display_name"],
                    bunq_user_id=profile["bunq_user_id"],
                    primary_iban=profile["primary_iban"],
                )
            )
        except Exception as e:  # noqa: BLE001
            log.warning("auth.bunq.list.skip", label=label, error=str(e))
    return cards


@router.post("", response_model=BunqSigninResponse)
async def signin_with_bunq(body: BunqSigninRequest) -> BunqSigninResponse:
    """Authenticate via a cached bunq sandbox session + issue a Supabase OTP."""
    try:
        profile = await _bunq_profile(body.label)
    except RuntimeError as e:
        raise HTTPException(status_code=404, detail=str(e)) from e

    display_name: str = profile["display_name"]
    bunq_user_id = profile["bunq_user_id"]
    email = f"{body.label}@kitty.demo"

    sb = get_supabase()

    # 1. Find or create the Supabase auth user.
    auth_user = _find_user_by_email(sb, email)
    if not auth_user:
        created = sb.auth.admin.create_user(
            {
                "email": email,
                "email_confirm": True,
                "user_metadata": {
                    "display_name": display_name,
                    "bunq_user_id": bunq_user_id,
                    "bunq_label": body.label,
                },
            }
        )
        auth_user = created.user
        log.info("auth.bunq.user.created", label=body.label, user_id=auth_user.id)

    # 2. Upsert our app-level profile (public.users).
    try:
        sb.table("users").upsert(
            {
                "id": str(auth_user.id),
                "display_name": display_name,
                "bunq_user_id": str(bunq_user_id) if bunq_user_id else None,
                "bunq_label": body.label,
            },
            on_conflict="id",
        ).execute()
    except Exception as e:  # noqa: BLE001
        log.warning("auth.bunq.profile.upsert_failed", error=str(e))

    # 3. Mint a single-use OTP bound to this email.
    link_resp = sb.auth.admin.generate_link(
        {"type": "magiclink", "email": email}
    )
    # supabase-py returns either dataclass-like `properties` or a dict — both OK.
    props = getattr(link_resp, "properties", None) or link_resp.get("properties", {})  # type: ignore[union-attr]
    email_otp = getattr(props, "email_otp", None) or props.get("email_otp")  # type: ignore[union-attr]
    if not email_otp:
        raise HTTPException(
            status_code=500,
            detail="supabase did not return an email OTP — check server-role key",
        )

    return BunqSigninResponse(email=email, otp=email_otp, expires_in=3600)


def _find_user_by_email(sb: Any, email: str) -> Any | None:
    """Iterate admin.list_users pages until we find a match."""
    try:
        # supabase-py list_users returns a list directly (not paginated at the API call)
        users = sb.auth.admin.list_users()
        for u in users or []:
            if getattr(u, "email", None) == email:
                return u
    except Exception as e:  # noqa: BLE001
        log.warning("auth.bunq.list_users.failed", error=str(e))
    return None
