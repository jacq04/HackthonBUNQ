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
    phone: str | None = None
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
    """Pull display_name (prefer UserPerson.display_name), the primary IBAN,
    and the first PHONE_NUMBER alias from bunq.
    """
    client = get_bunq_client(label)
    await client.ensure_session()

    display_name: str | None = None
    primary_iban: str | None = None
    phone: str | None = None

    try:
        profile = await client.get_user_profile()
        display_name = profile.get("display_name") or profile.get("public_nick_name")
        for alias in profile.get("alias") or []:
            if alias.get("type") == "PHONE_NUMBER" and not phone:
                phone = alias.get("value")
    except Exception as e:  # noqa: BLE001
        log.warning("auth.bunq.user_profile.failed", label=label, error=str(e))

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

    if not display_name:
        display_name = label.capitalize()

    return {
        "bunq_user_id": client.user_id,
        "display_name": display_name,
        "primary_iban": primary_iban,
        "phone": phone,
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
                    phone=profile.get("phone"),
                )
            )
        except Exception as e:  # noqa: BLE001
            log.warning("auth.bunq.list.skip", label=label, error=str(e))
    return cards


class PhoneSigninRequest(BaseModel):
    phone: str


@router.post("/by-phone", response_model=BunqSigninResponse)
async def signin_by_phone(body: PhoneSigninRequest) -> BunqSigninResponse:
    """Login by bunq phone number. Looks up the cached sandbox user whose
    PHONE_NUMBER alias matches, then runs the regular accept+OTP flow."""
    target = _normalize_phone(body.phone)
    if not target:
        raise HTTPException(status_code=400, detail="invalid phone number")

    ctx_dir = Path(os.path.expanduser(settings.bunq_context_dir))
    if not ctx_dir.exists():
        raise HTTPException(status_code=404, detail="no bunq users provisioned")

    matched_label: str | None = None
    for ctx_file in sorted(ctx_dir.glob("*.json")):
        label = ctx_file.stem
        try:
            profile = await _bunq_profile(label)
            if _normalize_phone(profile.get("phone") or "") == target:
                matched_label = label
                break
        except Exception as e:  # noqa: BLE001
            log.warning("auth.bunq.phone.lookup_failed", label=label, error=str(e))

    if not matched_label:
        raise HTTPException(
            status_code=404,
            detail="no bunq user with that phone number is provisioned on this host",
        )

    return await signin_with_bunq(BunqSigninRequest(label=matched_label))


def _normalize_phone(raw: str) -> str:
    """Keep only digits; drop a leading 00 (some sandbox users store the intl
    prefix that way). Allows comparisons to work whether the client sent
    '+31618053181', '0031618053181', '06 18053181', or '+31 6 1805 3181'."""
    digits = "".join(ch for ch in (raw or "") if ch.isdigit())
    if digits.startswith("00"):
        digits = digits[2:]
    # Local NL format — strip the leading 0 and prefix with 31 so both formats collide.
    if digits.startswith("0") and len(digits) in (10, 11):
        digits = "31" + digits[1:]
    return digits


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
