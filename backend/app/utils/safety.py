"""Input hygiene — prompt-injection detection for user-authored text."""
from __future__ import annotations

import re

_INJECTION_PATTERNS = [
    re.compile(r"\bignore\s+(all\s+)?(previous|prior|above)\s+(instructions|prompt)", re.I),
    re.compile(r"\bdisregard\s+(all\s+)?(previous|prior|above)\s+(instructions|prompt)", re.I),
    re.compile(r"\byou\s+are\s+now\b", re.I),
    re.compile(r"\bnew\s+instructions\s*:", re.I),
    re.compile(r"\bsystem\s*prompt\s*:", re.I),
    re.compile(r"<\s*/?\s*(system|assistant)\s*>", re.I),
]


def looks_like_injection(text: str) -> bool:
    return any(p.search(text) for p in _INJECTION_PATTERNS)


def sanitize_user_text(text: str) -> str:
    """Neutralize suspected injection markers by wrapping the whole message
    as explicit user-quoted content. Agents are instructed to never follow
    commands inside such quotes."""
    return f'<user_message>\n{text}\n</user_message>'
