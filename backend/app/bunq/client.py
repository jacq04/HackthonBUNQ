"""bunq API client — async httpx wrapper.

Session cache is toolkit-compatible: the context file has the same schema the
bunq hackathon toolkit's `bunq_context.json` uses. You can run the toolkit's
`01_authentication.py` to mint a session, then our FastAPI backend picks it up
transparently — and vice versa.

Multi-user mode: a single running backend can serve multiple sandbox users
(asha, malik, priya, …) by keeping one context file per label at
`~/.kitty/bunq-contexts/<label>.json`. Route handlers pass `label` into
`get_bunq_client(label)` to target the right user for the action.
"""
from __future__ import annotations

import asyncio
import base64
import json
import os
import uuid
from pathlib import Path
from typing import Any

import httpx
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa

from app.config import settings
from app.utils.logging import get_logger
from app.utils.tls import make_ssl_context

log = get_logger(__name__)

SANDBOX_USER_ENDPOINT = "/sandbox-user-person"


def context_path_for(label: str) -> Path:
    """Resolve the on-disk context file for a given user label.

    Order of precedence:
      1. BUNQ_CONTEXT_FILE env override (single-file toolkit-compat mode).
      2. <BUNQ_CONTEXT_DIR>/<label>.json  (multi-user mode).
    """
    override = settings.bunq_context_file
    if override:
        return Path(os.path.expanduser(override)).resolve()
    base = Path(os.path.expanduser(settings.bunq_context_dir)).resolve()
    base.mkdir(parents=True, exist_ok=True)
    return base / f"{label}.json"


class BunqClient:
    """Async bunq client. Can either (a) reuse a toolkit-written session context
    from disk, or (b) run the 3-step installation/device/session handshake
    itself using `api_key`."""

    def __init__(self, *, label: str = "default", api_key: str | None = None) -> None:
        self.label = label
        self._api_key: str | None = api_key or settings.bunq_api_key or None
        self._context_file = context_path_for(label)

        self._private_key: rsa.RSAPrivateKey | None = None
        self._public_key_pem: str | None = None
        self._installation_token: str | None = None
        self._server_public_key: str | None = None
        self._session_token: str | None = None
        self._user_id: int | None = None

        self._http = httpx.AsyncClient(
            base_url=settings.bunq_base_url, timeout=15.0, verify=make_ssl_context()
        )
        self._session_lock = asyncio.Lock()

    @property
    def user_id(self) -> int | None:
        return self._user_id

    # -------------------------------------------------------------------------
    # Context persistence (toolkit-compatible JSON schema)
    # -------------------------------------------------------------------------
    def _save_context(self) -> None:
        assert self._private_key is not None
        ctx = {
            "api_key": self._api_key,
            "sandbox": "sandbox" in settings.bunq_base_url,
            "private_key_pem": self._private_key.private_bytes(
                serialization.Encoding.PEM,
                serialization.PrivateFormat.PKCS8,
                serialization.NoEncryption(),
            ).decode(),
            "installation_token": self._installation_token,
            "server_public_key": self._server_public_key,
            "session_token": self._session_token,
            "user_id": self._user_id,
        }
        self._context_file.parent.mkdir(parents=True, exist_ok=True)
        self._context_file.write_text(json.dumps(ctx, indent=2))
        os.chmod(self._context_file, 0o600)
        log.info("bunq.context.saved", label=self.label, path=str(self._context_file))

    def _load_context(self) -> bool:
        if not self._context_file.exists():
            return False
        try:
            ctx = json.loads(self._context_file.read_text())
        except (json.JSONDecodeError, OSError):
            return False
        # Key mismatch → re-auth.
        if self._api_key and ctx.get("api_key") != self._api_key:
            log.warning("bunq.context.key_mismatch", label=self.label)
            return False
        self._api_key = ctx.get("api_key")
        self._private_key = serialization.load_pem_private_key(
            ctx["private_key_pem"].encode(), password=None
        )
        self._public_key_pem = self._private_key.public_key().public_bytes(
            serialization.Encoding.PEM,
            serialization.PublicFormat.SubjectPublicKeyInfo,
        ).decode()
        self._installation_token = ctx.get("installation_token")
        self._server_public_key = ctx.get("server_public_key")
        self._session_token = ctx.get("session_token")
        self._user_id = ctx.get("user_id")
        return bool(self._session_token and self._user_id)

    # -------------------------------------------------------------------------
    # Handshake
    # -------------------------------------------------------------------------
    async def ensure_session(self) -> None:
        """Idempotent. Loads a cached session, else performs the 3-step auth."""
        async with self._session_lock:
            if self._session_token:
                return
            if self._load_context() and await self._probe_session():
                return

            if not self._api_key:
                raise RuntimeError(
                    f"No cached bunq context for label='{self.label}' and no "
                    "BUNQ_API_KEY set. Run `python -m scripts.bunq_bootstrap "
                    f"create --label {self.label}` to mint a sandbox user."
                )

            # Fresh keypair — the toolkit regenerates on every auth, so do we.
            self._private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
            self._public_key_pem = self._private_key.public_key().public_bytes(
                serialization.Encoding.PEM,
                serialization.PublicFormat.SubjectPublicKeyInfo,
            ).decode()

            await self._step_installation()
            await self._step_device_server()
            await self._step_session_server()
            self._save_context()

    async def _probe_session(self) -> bool:
        """Hit a cheap authenticated endpoint to confirm the session still works."""
        try:
            resp = await self._http.get(
                f"/user/{self._user_id}", headers=self._auth_headers()
            )
            return resp.status_code == 200
        except Exception:  # noqa: BLE001
            return False

    async def _step_installation(self) -> None:
        body = {"client_public_key": self._public_key_pem}
        resp = await self._http.post("/installation", json=body, headers=_base_headers())
        resp.raise_for_status()
        for item in resp.json()["Response"]:
            if "Token" in item:
                self._installation_token = item["Token"]["token"]
            if "ServerPublicKey" in item:
                self._server_public_key = item["ServerPublicKey"]["server_public_key"]

    async def _step_device_server(self) -> None:
        body = {
            "description": settings.bunq_device_description,
            "secret": self._api_key,
            "permitted_ips": ["*"],
        }
        await self._signed_post("/device-server", body, with_installation=True)

    async def _step_session_server(self) -> None:
        body = {"secret": self._api_key}
        resp = await self._signed_post("/session-server", body, with_installation=True)
        for item in resp.json()["Response"]:
            if "Token" in item:
                self._session_token = item["Token"]["token"]
            for key in ("UserPerson", "UserCompany", "UserApiKey"):
                if key in item:
                    self._user_id = item[key]["id"]
        log.info("bunq.session.ready", label=self.label, user_id=self._user_id)

    # -------------------------------------------------------------------------
    # Signed requests
    # -------------------------------------------------------------------------
    def _sign(self, body: bytes) -> str:
        assert self._private_key is not None
        sig = self._private_key.sign(body, padding.PKCS1v15(), hashes.SHA256())
        return base64.b64encode(sig).decode()

    def _auth_headers(self) -> dict[str, str]:
        assert self._session_token is not None
        headers = _base_headers()
        headers["X-Bunq-Client-Authentication"] = self._session_token
        return headers

    async def _signed_post(
        self, path: str, body: dict, *, with_installation: bool = False
    ) -> httpx.Response:
        payload = json.dumps(body).encode()
        headers = _base_headers()
        if with_installation and self._installation_token:
            headers["X-Bunq-Client-Authentication"] = self._installation_token
        elif self._session_token:
            headers["X-Bunq-Client-Authentication"] = self._session_token
        headers["X-Bunq-Client-Signature"] = self._sign(payload)
        resp = await self._http.post(path, content=payload, headers=headers)
        resp.raise_for_status()
        return resp

    # -------------------------------------------------------------------------
    # Public API — the subset the backend needs.
    # -------------------------------------------------------------------------
    async def list_monetary_accounts(self) -> list[dict[str, Any]]:
        await self.ensure_session()
        resp = await self._http.get(
            f"/user/{self._user_id}/monetary-account-bank",
            headers=self._auth_headers(),
        )
        resp.raise_for_status()
        return [_unbox(x) for x in resp.json()["Response"]]

    async def get_primary_account_id(self) -> int:
        accs = await self.list_monetary_accounts()
        for a in accs:
            if a.get("status") == "ACTIVE":
                return int(a["id"])
        raise RuntimeError("no active monetary account found")

    async def create_joint_account(
        self, *, description: str, currency: str = "EUR"
    ) -> dict[str, Any]:
        await self.ensure_session()
        body = {"currency": currency, "description": description}
        resp = await self._signed_post(
            f"/user/{self._user_id}/monetary-account-bank", body
        )
        return _first_response(resp.json())

    async def create_request_inquiry(
        self,
        *,
        from_account_id: int,
        amount_cents: int,
        counterparty_email: str,
        description: str,
        currency: str = "EUR",
    ) -> dict[str, Any]:
        await self.ensure_session()
        body = {
            "amount_inquired": {"value": f"{amount_cents / 100:.2f}", "currency": currency},
            "counterparty_alias": {"type": "EMAIL", "value": counterparty_email},
            "description": description,
            "allow_bunqme": True,
        }
        resp = await self._signed_post(
            f"/user/{self._user_id}/monetary-account/{from_account_id}/request-inquiry",
            body,
        )
        return _first_response(resp.json())

    async def make_payment(
        self,
        *,
        from_account_id: int,
        amount_cents: int,
        counterparty_iban: str,
        counterparty_name: str,
        description: str,
        currency: str = "EUR",
    ) -> dict[str, Any]:
        await self.ensure_session()
        body = {
            "amount": {"value": f"{amount_cents / 100:.2f}", "currency": currency},
            "counterparty_alias": {
                "type": "IBAN",
                "value": counterparty_iban,
                "name": counterparty_name,
            },
            "description": description,
        }
        resp = await self._signed_post(
            f"/user/{self._user_id}/monetary-account/{from_account_id}/payment", body
        )
        return _first_response(resp.json())

    async def create_autoflow(
        self,
        *,
        from_account_id: int,
        description: str,
        monthly_cap_cents: int,
        debit_day: int,
        currency: str = "EUR",
    ) -> dict[str, Any]:
        """SEPA-style auto-debit mandate.

        bunq's sandbox does not expose a stable 'payment-autoflow' endpoint for
        3rd-party orchestration. We emit a deterministic sandbox mandate id and
        log a warning so the rest of the lifecycle can continue. In production,
        swap this stub for an actual autoflow setup + periodic pulls.
        """
        await self.ensure_session()
        sandbox_id = f"SBX-AUTOFLOW-{uuid.uuid4().hex[:16]}"
        log.warning(
            "bunq.autoflow.sandbox_stub",
            label=self.label,
            account_id=from_account_id,
            debit_day=debit_day,
            monthly_cap_cents=monthly_cap_cents,
            sandbox_id=sandbox_id,
        )
        return {
            "id": sandbox_id,
            "monetary_account_id": from_account_id,
            "description": description,
            "monthly_cap": {"value": f"{monthly_cap_cents / 100:.2f}", "currency": currency},
            "debit_day": debit_day,
            "status": "ACTIVE",
            "sandbox": True,
        }

    async def revoke_autoflow(self, bunq_mandate_id: str) -> dict[str, Any]:
        """Mirror of create_autoflow — sandbox stub. No server round-trip."""
        log.warning("bunq.autoflow.revoke_sandbox_stub", mandate=bunq_mandate_id)
        return {"id": bunq_mandate_id, "status": "REVOKED", "sandbox": True}

    async def request_test_funds(
        self, *, to_account_id: int, amount_cents: int = 50000
    ) -> dict[str, Any]:
        """Sandbox-only: ask sugardaddy@bunq.com for test EUR."""
        await self.ensure_session()
        body = {
            "amount_inquired": {"value": f"{amount_cents / 100:.2f}", "currency": "EUR"},
            "counterparty_alias": {"type": "EMAIL", "value": "sugardaddy@bunq.com"},
            "description": "test funds for Kitty demo",
            "allow_bunqme": False,
        }
        resp = await self._signed_post(
            f"/user/{self._user_id}/monetary-account/{to_account_id}/request-inquiry",
            body,
        )
        return _first_response(resp.json())

    async def list_payments(
        self, *, account_id: int, count: int = 200
    ) -> list[dict[str, Any]]:
        await self.ensure_session()
        resp = await self._http.get(
            f"/user/{self._user_id}/monetary-account/{account_id}/payment",
            params={"count": count},
            headers=self._auth_headers(),
        )
        resp.raise_for_status()
        return [_unbox(x) for x in resp.json()["Response"]]

    async def register_webhook(
        self,
        *,
        account_id: int,
        url: str,
        event_types: list[str] | None = None,
    ) -> dict[str, Any]:
        await self.ensure_session()
        body = {
            "notification_filters": [
                {"category": et, "notification_delivery_method": "URL", "notification_target": url}
                for et in (event_types or ["PAYMENT"])
            ],
        }
        resp = await self._signed_post(
            f"/user/{self._user_id}/monetary-account/{account_id}/notification-filter-url",
            body,
        )
        return _first_response(resp.json())

    async def close(self) -> None:
        await self._http.aclose()


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
def _base_headers() -> dict[str, str]:
    return {
        "Content-Type": "application/json",
        "Cache-Control": "no-cache",
        "User-Agent": "kitty-hackathon/0.1",
        "X-Bunq-Client-Request-Id": str(uuid.uuid4()),
        "X-Bunq-Language": "en_US",
        "X-Bunq-Region": "nl_NL",
        "X-Bunq-Geolocation": "0 0 0 0 000",
    }


def _unbox(item: dict[str, Any]) -> dict[str, Any]:
    if isinstance(item, dict) and len(item) == 1:
        return next(iter(item.values()))
    return item


def _first_response(payload: dict[str, Any]) -> dict[str, Any]:
    resp = payload.get("Response") or []
    if not resp:
        return {}
    return _unbox(resp[0])


# -----------------------------------------------------------------------------
# Singleton registry — one client per label, shared across the process.
# -----------------------------------------------------------------------------
_clients: dict[str, BunqClient] = {}


def get_bunq_client(label: str | None = None) -> BunqClient:
    key = label or settings.bunq_default_label
    client = _clients.get(key)
    if client is None:
        client = BunqClient(label=key)
        _clients[key] = client
    return client
