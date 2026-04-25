"""Materialize bunq session-context files from env vars on container start.

In production we can't ship the local ~/.kitty/bunq-contexts/<label>.json
files directly — they live on the developer's laptop. The simple pattern
is: each context file is stashed as a Fly secret named BUNQ_CTX_<LABEL>
(value is the JSON string), and at lifespan startup we write them out to
the path the rest of the app already reads from.

  fly secrets set --app pod-backend \\
      BUNQ_CTX_ASHA="$(cat ~/.kitty/bunq-contexts/asha.json)" \\
      BUNQ_CTX_TUNDE="$(cat ~/.kitty/bunq-contexts/tunde.json)" ...

Idempotent — files that already exist on disk are not overwritten unless
their content has changed (so a redeploy with updated session tokens
takes effect).
"""

from __future__ import annotations

import os
from pathlib import Path

from app.config import settings
from app.utils.logging import get_logger

log = get_logger(__name__)

ENV_PREFIX = "BUNQ_CTX_"


def materialize_context_files() -> int:
    """Write each BUNQ_CTX_<LABEL> env var to <BUNQ_CONTEXT_DIR>/<label>.json.

    Returns the number of files written or refreshed.
    """
    ctx_dir = Path(os.path.expanduser(settings.bunq_context_dir)).resolve()
    ctx_dir.mkdir(parents=True, exist_ok=True)

    written = 0
    for key, value in os.environ.items():
        if not key.startswith(ENV_PREFIX):
            continue
        label = key[len(ENV_PREFIX):].lower()
        if not label or not value:
            continue
        path = ctx_dir / f"{label}.json"
        # Only rewrite if content changed — preserves on-disk session-token
        # rotations between restarts.
        prior = path.read_text() if path.exists() else None
        if prior == value:
            continue
        path.write_text(value)
        written += 1
        log.info(
            "kitty.bunq.context_materialized",
            label=label,
            path=str(path),
            replaced=prior is not None,
        )

    return written
