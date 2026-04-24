# bunq Sandbox Users

Paste your sandbox user credentials here. The backend reads this file in two modes:

- **Declarative**: list the users you already created (API keys from `/sandbox-user-person`).
- **Bootstrap**: leave the API-key column blank and run `python -m scripts.bunq_bootstrap create` — the script
  mints a new sandbox user for each blank row and fills in the details.

Each authenticated user's session is cached at `~/.kitty/bunq-contexts/<label>.json` in the same
format as the bunq hackathon toolkit's `bunq_context.json` (so `python third_party/bunq_toolkit/01_authentication.py`
works interchangeably with our FastAPI backend).

## Users

| label   | email                | api_key                                  | user_id | primary_iban        | notes                               |
|---------|----------------------|------------------------------------------|---------|---------------------|-------------------------------------|
| asha    | asha@kitty.demo      |                                          |         |                     | group founder, Lagos Crew           |
| malik   | malik@kitty.demo     |                                          |         |                     | member — triggers live dispute demo |
| priya   | priya@kitty.demo     |                                          |         |                     | member — triggers emergency exit    |
| tunde   | tunde@kitty.demo     |                                          |         |                     | late payer — Collector escalates    |
| fatou   | fatou@kitty.demo     |                                          |         |                     | recipient of cycle 3 payout         |
| raj     | raj@kitty.demo       |                                          |         |                     | observer / 2nd device on stage      |

## Sandbox test funds

Each new sandbox user starts with €0. The toolkit recommends requesting €500 from `sugardaddy@bunq.com`:

```bash
python -m scripts.bunq_request_test_funds --label asha --amount 500
```

## Notes for demo day

- API keys here are **sandbox only** — they won't work against production. Safe to commit to a private repo; avoid committing to a public one.
- If you rotate a key, run `python -m scripts.bunq_bootstrap rotate --label <name>` to re-authenticate and refresh the cached session.
