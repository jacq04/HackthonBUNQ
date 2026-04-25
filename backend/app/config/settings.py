from __future__ import annotations

from functools import lru_cache
from pathlib import Path

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=[
            # Prefer repo-root .env; fall back to backend/.env.
            str(Path(__file__).resolve().parents[3] / ".env"),
            str(Path(__file__).resolve().parents[2] / ".env"),
        ],
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )

    env: str = "development"
    log_level: str = "INFO"
    backend_port: int = 8000
    public_base_url: str = "http://localhost:8000"
    passport_hmac_secret: str = "dev-only-change-me"

    # Supabase
    supabase_url: str = ""
    supabase_anon_key: str = ""
    supabase_service_role_key: str = ""
    supabase_db_url: str = ""

    # Anthropic
    anthropic_api_key: str = ""
    claude_reasoner_model: str = "claude-sonnet-4-6"
    claude_fast_model: str = "claude-haiku-4-5-20251001"

    # TigerBeetle
    tigerbeetle_addresses: str = "127.0.0.1:3000"
    tigerbeetle_cluster_id: int = 0

    # bunq
    bunq_api_key: str = ""
    bunq_base_url: str = "https://public-api.sandbox.bunq.com/v1"
    bunq_device_description: str = "kitty-hackathon-dev"
    bunq_webhook_secret: str = ""
    # Multi-sandbox-user storage. One context file per label — compatible with
    # the bunq hackathon toolkit's bunq_context.json format.
    bunq_context_dir: str = "~/.kitty/bunq-contexts"
    bunq_default_label: str = "default"
    # The bunq label whose monetary account collects ROSCA contributions.
    # Conventionally Asha — she is the platform admin, not a member.
    bunq_platform_label: str = "asha"
    # Admin fee retained from each cycle's payout, in basis points.
    # 500 bps = 5% — winner receives the remaining 95% of the pot.
    payout_admin_fee_bps: int = 500
    # If set, overrides bunq_context_dir — used for single-file toolkit compatibility.
    bunq_context_file: str = ""

    @property
    def is_production(self) -> bool:
        return self.env.lower() == "production"


@lru_cache
def get_settings() -> Settings:
    return Settings()


settings: Settings = get_settings()
