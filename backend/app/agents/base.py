"""Agent base class.

Implements:
  - System-prompt + tool-list prompt caching (Anthropic ephemeral cache).
  - Iterative tool-use loop: invoke → parse tool_use blocks → dispatch →
    append tool_result → re-invoke until stop_reason == 'end_turn'.
  - Audit logging of every tool call.
  - Prompt-injection sanitization on user-authored messages.

Subclasses declare:
  NAME, MODEL_SETTING, SYSTEM_PROMPT, TOOLS (list of ToolSpec)

and implement `async def handle_tool(self, name, input) -> Any`.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any

from anthropic import AsyncAnthropic
from anthropic.types import Message, MessageParam, ToolParam, ToolUseBlock

from app.agents.anthropic_client import get_claude
from app.config import settings
from app.utils.logging import get_logger
from app.utils.safety import sanitize_user_text

log = get_logger(__name__)


@dataclass
class ToolSpec:
    name: str
    description: str
    input_schema: dict[str, Any]


@dataclass
class AgentResult:
    text: str
    tool_calls: list[dict[str, Any]] = field(default_factory=list)
    stop_reason: str | None = None
    raw_messages: list[MessageParam] = field(default_factory=list)


class BaseAgent:
    NAME: str = "base"
    MODEL_SETTING: str = "claude_reasoner_model"  # or 'claude_fast_model'
    SYSTEM_PROMPT: str = ""
    TOOLS: list[ToolSpec] = []
    MAX_TURNS: int = 8

    def __init__(self) -> None:
        self._client: AsyncAnthropic = get_claude()

    # -------------------------------------------------------------------------
    # Subclass hooks
    # -------------------------------------------------------------------------
    async def handle_tool(self, name: str, input: dict[str, Any]) -> Any:
        raise NotImplementedError

    # -------------------------------------------------------------------------
    # Run loop
    # -------------------------------------------------------------------------
    async def run(
        self,
        user_text: str,
        *,
        history: list[MessageParam] | None = None,
        context: dict[str, Any] | None = None,
    ) -> AgentResult:
        """Run the agent until it stops calling tools.

        `context` is available to handle_tool via self._context for the duration.
        """
        self._context = context or {}
        sanitized = sanitize_user_text(user_text)
        messages: list[MessageParam] = list(history or [])
        messages.append({"role": "user", "content": sanitized})

        tool_calls: list[dict[str, Any]] = []
        model = getattr(settings, self.MODEL_SETTING)

        system_blocks = [
            {
                "type": "text",
                "text": self.SYSTEM_PROMPT,
                "cache_control": {"type": "ephemeral"},
            }
        ]
        tool_params: list[ToolParam] = [
            {
                "name": t.name,
                "description": t.description,
                "input_schema": t.input_schema,
            }
            for t in self.TOOLS
        ]
        if tool_params:
            # Mark the last tool for caching — caches everything above it.
            tool_params[-1] = {**tool_params[-1], "cache_control": {"type": "ephemeral"}}

        for turn in range(self.MAX_TURNS):
            log.debug("agent.turn", agent=self.NAME, turn=turn)
            resp: Message = await self._client.messages.create(
                model=model,
                max_tokens=2048,
                system=system_blocks,
                tools=tool_params or None,
                messages=messages,
            )

            # Append assistant turn.
            messages.append({"role": "assistant", "content": resp.content})

            if resp.stop_reason != "tool_use":
                text = _extract_text(resp)
                return AgentResult(
                    text=text,
                    tool_calls=tool_calls,
                    stop_reason=resp.stop_reason,
                    raw_messages=messages,
                )

            # Dispatch every tool_use block this turn in one batch.
            tool_use_blocks = [b for b in resp.content if isinstance(b, ToolUseBlock)]
            tool_results = []
            for block in tool_use_blocks:
                log.info(
                    "agent.tool_call",
                    agent=self.NAME,
                    tool=block.name,
                    input=block.input,
                )
                try:
                    result = await self.handle_tool(block.name, dict(block.input))
                    tool_calls.append(
                        {"name": block.name, "input": block.input, "result": result}
                    )
                    payload = json.dumps(result, default=str) if not isinstance(result, str) else result
                    tool_results.append(
                        {
                            "type": "tool_result",
                            "tool_use_id": block.id,
                            "content": payload,
                        }
                    )
                except Exception as e:  # noqa: BLE001
                    log.exception("agent.tool_error", agent=self.NAME, tool=block.name)
                    tool_results.append(
                        {
                            "type": "tool_result",
                            "tool_use_id": block.id,
                            "is_error": True,
                            "content": f"Error: {e}",
                        }
                    )
            messages.append({"role": "user", "content": tool_results})

        raise RuntimeError(f"Agent {self.NAME} exceeded MAX_TURNS={self.MAX_TURNS}")


def _extract_text(resp: Message) -> str:
    parts: list[str] = []
    for block in resp.content:
        if hasattr(block, "text"):
            parts.append(block.text)
    return "".join(parts).strip()
