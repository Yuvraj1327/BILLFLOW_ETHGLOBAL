"""Small helpers shared by services."""
from __future__ import annotations

from app.core.config import Settings
from app.core.exceptions import unavailable
from app.utils.validators import from_base

ACTIVE_FINANCING = ("REQUESTED", "UNDER_REVIEW", "APPROVED", "LISTED", "FUNDED", "DEFAULTED")


def decimals(s: Settings) -> int:
    """Token decimals are configuration that MUST be verified against the token (preflight) - never assumed."""
    if s.usdt_decimals is None:
        raise unavailable("usdt_decimals_not_configured",
                          "USDT_DECIMALS is not configured. Read decimals() from the verified token and set it.")
    return s.usdt_decimals


def money(n, dec: int) -> str:
    return from_base(n, dec) or "0"


def explorer_tx(s: Settings, tx_hash: str | None) -> str | None:
    return f"{s.whitechain_explorer_url.rstrip('/')}/tx/{tx_hash}" if tx_hash else None
