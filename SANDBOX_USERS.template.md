# bunq Sandbox Users — template

**This file is a template.** At runtime the bootstrap script copies it to `SANDBOX_USERS.md` (which is git-ignored) before filling in keys and IBANs. Never commit the filled version — the repo is public and even sandbox keys don't belong in public git history.

Flow:

1. Copy this file to `SANDBOX_USERS.md` (the bootstrap does this automatically if the file is missing).
2. Edit the `label` / `email` / `notes` columns as you like.
3. Run `make bunq-bootstrap` — blank `api_key` rows get minted as new sandbox users and filled in.

Each authenticated user's session is cached at `~/.kitty/bunq-contexts/<label>.json` in the same format as the bunq hackathon toolkit's `bunq_context.json` (so `python third_party/bunq_toolkit/01_authentication.py` works interchangeably with our FastAPI backend).

## Users

Bootstrap populates `api_key`, `user_id`, `primary_iban`, and the bunq
`phone` number (each sandbox user is assigned a `+31…` number). The phone
number is what you type on the Kitty sign-in screen — any format works
(`+31 6 1805 3181`, `0618053181`, etc. — the backend normalizes).

| label   | email                | api_key | user_id | primary_iban | phone | notes                               |
|---------|----------------------|---------|---------|--------------|-------|-------------------------------------|
| asha    | asha@kitty.demo      |         |         |              |       | group founder, Lagos Crew           |
| malik   | malik@kitty.demo     |         |         |              |       | member — triggers live dispute demo |
| priya   | priya@kitty.demo     |         |         |              |       | member — triggers emergency exit    |
| tunde   | tunde@kitty.demo     |         |         |              |       | late payer — Collector escalates    |
| fatou   | fatou@kitty.demo     |         |         |              |       | recipient of cycle 3 payout         |
| raj     | raj@kitty.demo       |         |         |              |       | observer / 2nd device on stage      |

## Sandbox test funds

Each new sandbox user starts with €0. Request €500 from `sugardaddy@bunq.com`:

```bash
make bunq-funds LABEL=asha AMOUNT=500
```

## Notes

- API keys in your local `SANDBOX_USERS.md` are **sandbox only** — they won't work against production. Still, don't leak them — git-ignored for that reason.
- If you rotate a key, run `python -m scripts.bunq_bootstrap rotate --label <name>` to re-authenticate and refresh the cached session.
  ┌───────┬──────────────┬──────────────┐
  │ label │ display name │    phone     │
  ├───────┼──────────────┼──────────────┤
  │ asha  │ A. Stewart   │ +31618053181 │
  ├───────┼──────────────┼──────────────┤
  │ malik │ M. Luu       │ +31618056688 │
  ├───────┼──────────────┼──────────────┤
  │ priya │ T. Smith     │ +31618059655 │
  ├───────┼──────────────┼──────────────┤
  │ tunde │ W. Warren    │ +31618062287 │
  ├───────┼──────────────┼──────────────┤
  │ fatou │ B. Karapinar │ +31618065397 │
  ├───────┼──────────────┼──────────────┤
  │ raj   │ I. Stewart   │ +31618068593 │
  └───────┴──────────────┴──────────────┘
  ┌───────┬──────────────┬──────────────┐
  │ label │    phone     │ display name │
  ├───────┼──────────────┼──────────────┤
  │ ahmed │ +31617113970 │ T. Matthews  │
  ├───────┼──────────────┼──────────────┤
  │ chen  │ +31617116972 │ D. Cadieux   │
  ├───────┼──────────────┼──────────────┤
  │ iris  │ +31617119559 │ S. Quinlan   │
  ├───────┼──────────────┼──────────────┤
  │ kofi  │ +31617122907 │ L. The       │
