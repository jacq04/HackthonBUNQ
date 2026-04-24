"""bunq sandbox bootstrap — one CLI, many sandbox users.

Bridges the vendored bunq hackathon toolkit (third_party/bunq_toolkit) to our
FastAPI backend. Uses the toolkit's `BunqClient` to mint sandbox users and
authenticate API keys, then writes the resulting session context in the
toolkit's own JSON format so our async backend can read it.

Usage:
    # 1. Create a sandbox user for each row in SANDBOX_USERS.md that has a
    #    label but no api_key.
    python -m scripts.bunq_bootstrap create-from-md

    # 2. Authenticate an already-existing API key:
    python -m scripts.bunq_bootstrap create --label asha --api-key sandbox_xxx

    # 3. Request €500 test funds for a user's primary account:
    python -m scripts.bunq_bootstrap test-funds --label asha --amount 500

    # 4. List what's authenticated locally:
    python -m scripts.bunq_bootstrap list

    # 5. Rotate (re-authenticate) a label:
    python -m scripts.bunq_bootstrap rotate --label asha
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

# Make the vendored toolkit importable.
REPO_ROOT = Path(__file__).resolve().parents[2]
TOOLKIT_PATH = REPO_ROOT / "third_party" / "bunq_toolkit"
if TOOLKIT_PATH.exists() and str(TOOLKIT_PATH) not in sys.path:
    sys.path.insert(0, str(TOOLKIT_PATH))

try:
    from bunq_client import BunqClient as ToolkitClient  # type: ignore
except ImportError as e:
    print(
        "Toolkit not found. Run:\n"
        "  git clone --depth 1 https://github.com/bunq/hackathon_toolkit "
        f"{TOOLKIT_PATH}\n",
        file=sys.stderr,
    )
    raise SystemExit(1) from e

from app.bunq.client import context_path_for  # noqa: E402
from app.config import settings  # noqa: E402

SANDBOX_USERS_MD = REPO_ROOT / "SANDBOX_USERS.md"


# -----------------------------------------------------------------------------
# Context writing — toolkit-compatible JSON shape, but keyed by label.
# -----------------------------------------------------------------------------
def _write_context(label: str, toolkit: ToolkitClient) -> Path:
    path = context_path_for(label)
    path.parent.mkdir(parents=True, exist_ok=True)
    from cryptography.hazmat.primitives import serialization

    ctx = {
        "api_key": toolkit.api_key,
        "sandbox": toolkit.sandbox,
        "private_key_pem": toolkit._private_key.private_bytes(  # noqa: SLF001
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        ).decode(),
        "installation_token": toolkit.installation_token,
        "server_public_key": toolkit.server_public_key,
        "session_token": toolkit.session_token,
        "user_id": toolkit.user_id,
    }
    path.write_text(json.dumps(ctx, indent=2))
    path.chmod(0o600)
    return path


# -----------------------------------------------------------------------------
# SANDBOX_USERS.md parser — minimal markdown-table reader.
# -----------------------------------------------------------------------------
_HEADER_RE = re.compile(r"^\|\s*label\s*\|", re.I)


def parse_md_table() -> list[dict[str, str]]:
    if not SANDBOX_USERS_MD.exists():
        return []
    lines = SANDBOX_USERS_MD.read_text().splitlines()
    rows: list[dict[str, str]] = []
    headers: list[str] | None = None
    for line in lines:
        if _HEADER_RE.match(line):
            headers = [c.strip() for c in line.strip("|").split("|")]
            continue
        if headers is None:
            continue
        if line.strip().startswith("|---"):
            continue
        if not line.strip().startswith("|"):
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if len(cells) != len(headers):
            continue
        rows.append(dict(zip(headers, cells)))
    return rows


def write_md_table(rows: list[dict[str, str]]) -> None:
    """Rewrite SANDBOX_USERS.md preserving the preamble, replacing the table."""
    original = SANDBOX_USERS_MD.read_text()
    header_match = re.search(r"^\| *label.*?$", original, flags=re.M | re.I)
    if not header_match:
        return
    # Find the end of the existing table.
    start = header_match.start()
    lines = original[start:].splitlines()
    body_end = 0
    for i, line in enumerate(lines):
        if line.strip().startswith("|"):
            body_end = i + 1
        else:
            break
    preamble = original[:start]
    postamble = "\n".join(lines[body_end:]) if body_end < len(lines) else ""

    header_cols = [c.strip() for c in header_match.group(0).strip("|").split("|")]
    widths = [
        max(len(h), *(len(r.get(h, "")) for r in rows), 3) for h in header_cols
    ]

    def fmt_row(values: list[str]) -> str:
        return "| " + " | ".join(v.ljust(w) for v, w in zip(values, widths)) + " |"

    out = [fmt_row(header_cols), fmt_row(["-" * w for w in widths])]
    for r in rows:
        out.append(fmt_row([r.get(h, "") for h in header_cols]))

    SANDBOX_USERS_MD.write_text(preamble + "\n".join(out) + ("\n" + postamble if postamble else "\n"))


# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------
def cmd_create(args: argparse.Namespace) -> None:
    api_key = args.api_key
    if not api_key:
        print(f"[bootstrap] minting a new sandbox user for label={args.label} ...")
        api_key = ToolkitClient.create_sandbox_user()
        print(f"[bootstrap] got api_key: {api_key[:18]}…")

    tk = ToolkitClient(api_key=api_key, sandbox=True)
    tk.authenticate()
    path = _write_context(args.label, tk)
    # Fetch primary account for convenience.
    primary_iban = ""
    try:
        resp = tk.get(f"user/{tk.user_id}/monetary-account-bank")
        for item in resp:
            a = item.get("MonetaryAccountBank", {})
            if a.get("status") == "ACTIVE":
                for alias in a.get("alias", []):
                    if alias.get("type") == "IBAN":
                        primary_iban = alias.get("value", "")
                        break
                break
    except Exception as e:  # noqa: BLE001
        print(f"[bootstrap] couldn't fetch primary account: {e}")

    print(f"[bootstrap] user_id={tk.user_id}  iban={primary_iban or '(none)'}")
    print(f"[bootstrap] context saved to {path}")


def cmd_create_from_md(args: argparse.Namespace) -> None:
    rows = parse_md_table()
    if not rows:
        print("[bootstrap] SANDBOX_USERS.md has no table rows.", file=sys.stderr)
        sys.exit(1)

    changed = False
    for r in rows:
        label = r.get("label", "").strip()
        if not label:
            continue
        existing = r.get("api_key", "").strip()
        if existing:
            print(f"[bootstrap] {label}: already has an api_key — authenticating")
            api_key = existing
        else:
            print(f"[bootstrap] {label}: minting new sandbox user")
            api_key = ToolkitClient.create_sandbox_user()
            r["api_key"] = api_key
            changed = True

        tk = ToolkitClient(api_key=api_key, sandbox=True)
        tk.authenticate()
        _write_context(label, tk)
        r["user_id"] = str(tk.user_id or "")

        try:
            resp = tk.get(f"user/{tk.user_id}/monetary-account-bank")
            for item in resp:
                a = item.get("MonetaryAccountBank", {})
                if a.get("status") == "ACTIVE":
                    for alias in a.get("alias", []):
                        if alias.get("type") == "IBAN":
                            r["primary_iban"] = alias.get("value", "")
                            break
                    break
        except Exception as e:  # noqa: BLE001
            print(f"[bootstrap] {label}: couldn't fetch IBAN: {e}")

        print(f"  → user_id={tk.user_id}  iban={r.get('primary_iban', '(none)')}")

    if changed:
        write_md_table(rows)
        print("[bootstrap] SANDBOX_USERS.md updated with new keys + IBANs")


def cmd_test_funds(args: argparse.Namespace) -> None:
    path = context_path_for(args.label)
    if not path.exists():
        print(f"[bootstrap] no context at {path}. Run `create --label {args.label}` first.", file=sys.stderr)
        sys.exit(1)
    ctx = json.loads(path.read_text())
    tk = ToolkitClient(api_key=ctx["api_key"], sandbox=True)
    tk.authenticate()
    account_id = tk.get_primary_account_id()
    body = {
        "amount_inquired": {"value": f"{args.amount:.2f}", "currency": "EUR"},
        "counterparty_alias": {"type": "EMAIL", "value": "sugardaddy@bunq.com"},
        "description": f"test funds for {args.label}",
        "allow_bunqme": False,
    }
    tk.post(f"user/{tk.user_id}/monetary-account/{account_id}/request-inquiry", body)
    print(f"[bootstrap] requested €{args.amount:.2f} for {args.label} (account {account_id})")


def cmd_list(_: argparse.Namespace) -> None:
    base = Path(__file__).parent  # placeholder so linter doesn't complain
    import os as _os

    cdir = Path(_os.path.expanduser(settings.bunq_context_dir))
    if settings.bunq_context_file:
        cdir = Path(_os.path.expanduser(settings.bunq_context_file)).parent
    if not cdir.exists():
        print(f"[bootstrap] no context directory at {cdir}")
        return
    for p in sorted(cdir.glob("*.json")):
        try:
            ctx = json.loads(p.read_text())
            print(f"  {p.stem:12}  user_id={ctx.get('user_id')}  key={str(ctx.get('api_key'))[:12]}…")
        except Exception as e:  # noqa: BLE001
            print(f"  {p.stem:12}  (unreadable: {e})")


def cmd_rotate(args: argparse.Namespace) -> None:
    path = context_path_for(args.label)
    if not path.exists():
        print(f"[bootstrap] no context for {args.label}", file=sys.stderr)
        sys.exit(1)
    old = json.loads(path.read_text())
    api_key = old["api_key"]
    tk = ToolkitClient(api_key=api_key, sandbox=True)
    # Force a full re-auth by deleting the toolkit's cached context first
    # (the toolkit looks for `bunq_context.json` in CWD — we're not using that
    # filename, but the toolkit client regenerates the keypair on construction,
    # so calling authenticate() always re-auths unless _load_context succeeds).
    tk.authenticate()
    _write_context(args.label, tk)
    print(f"[bootstrap] rotated session for {args.label} (user_id={tk.user_id})")


# -----------------------------------------------------------------------------
# main
# -----------------------------------------------------------------------------
def main() -> None:
    parser = argparse.ArgumentParser(description="bunq sandbox bootstrap")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("create", help="Authenticate a sandbox user (mints one if --api-key not given)")
    p.add_argument("--label", required=True)
    p.add_argument("--api-key", default=None)
    p.set_defaults(func=cmd_create)

    p = sub.add_parser("create-from-md", help="Fill in every row of SANDBOX_USERS.md")
    p.set_defaults(func=cmd_create_from_md)

    p = sub.add_parser("test-funds", help="Request test EUR from sugardaddy@bunq.com")
    p.add_argument("--label", required=True)
    p.add_argument("--amount", type=float, default=500.0)
    p.set_defaults(func=cmd_test_funds)

    p = sub.add_parser("list", help="List cached sandbox sessions")
    p.set_defaults(func=cmd_list)

    p = sub.add_parser("rotate", help="Re-authenticate an existing label")
    p.add_argument("--label", required=True)
    p.set_defaults(func=cmd_rotate)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
