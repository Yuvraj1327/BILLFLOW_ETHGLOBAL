"""Application settings (environment variables / .env). No secrets in source code."""
from __future__ import annotations

from functools import lru_cache

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore", case_sensitive=False)

    app_env: str = "development"
    api_prefix: str = "/api/v1"
    cors_origins: str = ""  # comma separated
    public_checkout_base_url: str = "http://localhost:8080"
    log_level: str = "INFO"

    # Supabase
    supabase_url: str = ""
    supabase_anon_key: str = ""
    supabase_service_role_key: str = ""
    supabase_jwt_secret: str | None = None  # legacy HS256 projects
    supabase_jwt_jwks_url: str | None = None  # asymmetric signing keys
    supabase_jwt_audience: str = "authenticated"
    supabase_storage_bucket: str = "invoice-documents"
    database_url: str = ""  # trusted backend Postgres connection (service role / postgres)

    # Anthropic
    anthropic_api_key: str = ""
    anthropic_model: str = ""  # must be set explicitly
    ai_timeout_seconds: float = 60.0
    ai_max_pdf_pages: int = 20

    # Whitechain
    whitechain_rpc_url: str = ""
    whitechain_chain_id: int = 1874
    whitechain_explorer_url: str = "https://explorer.testnet.whitechain.io"
    whitechain_usdt_address: str = ""
    usdt_decimals: int | None = None  # verified against the token at preflight; never assumed
    whitechain_payment_contract: str = ""
    whitechain_financing_contract: str = ""
    # Step 2 merged the registry into the financing contract. If set it must equal the financing address.
    whitechain_invoice_registry: str = ""

    # Backend-held keys (testnet only). The quote signer authorises payments; it never moves user funds.
    quote_signer_private_key: str = ""
    quote_ttl_seconds: int = 900

    # Indexer / verification
    min_confirmations: int = 3
    indexer_enabled: bool = False
    indexer_poll_seconds: float = 5.0
    indexer_batch_blocks: int = 500
    indexer_start_block: int | None = None
    indexer_rescan_overlap: int = 12

    # Uploads / links
    max_upload_bytes: int = Field(default=10 * 1024 * 1024, gt=0)
    payment_link_ttl_days: int = 30
    public_rate_limit_per_minute: int = 60

    @field_validator("whitechain_usdt_address", "whitechain_payment_contract", "whitechain_financing_contract",
                     "whitechain_invoice_registry")
    @classmethod
    def _lower(cls, v: str) -> str:
        return v.strip().lower()

    @property
    def cors_list(self) -> list[str]:
        return [o.strip() for o in self.cors_origins.split(",") if o.strip()]

    @property
    def is_production(self) -> bool:
        return self.app_env.lower() == "production"


@lru_cache
def get_settings() -> Settings:
    return Settings()
