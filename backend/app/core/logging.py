from __future__ import annotations

import logging
import re

_LABELLED = re.compile(r"(?i)(bearer\s+|api[_-]?key[=:]\s*|private[_-]?key[=:]\s*)[A-Za-z0-9._\-]+")
_URL_CREDS = re.compile(r"(?i)([a-z][a-z0-9+.\-]*://[^/\s:@]+:)[^@\s/]+@")
_JWT = re.compile(r"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]*")
_SECRET_FIELDS = ("supabase_service_role_key", "supabase_anon_key", "supabase_jwt_secret", "anthropic_api_key", "quote_signer_private_key")


def _configured_secrets() -> list[str]:
    """Exact values of every configured secret (so a leaked value is scrubbed whatever the surrounding text is)."""
    from app.core.config import get_settings
    s = get_settings()
    vals = [getattr(s, f) for f in _SECRET_FIELDS if getattr(s, f, None)]
    if s.quote_signer_private_key:  # also the form without the 0x prefix
        vals.append(s.quote_signer_private_key.removeprefix("0x"))
    return sorted({v for v in vals if len(v) >= 8}, key=len, reverse=True)


class RedactFilter(logging.Filter):
    """Scrubs secrets from log records: configured secret values, bearer tokens, JWTs and passwords inside URLs.

    Transaction hashes are deliberately NOT scrubbed (they are public and needed for debugging)."""

    def filter(self, record: logging.LogRecord) -> bool:
        try:
            msg = str(record.getMessage())
            for v in _configured_secrets():
                msg = msg.replace(v, "[REDACTED]")
            msg = _URL_CREDS.sub(r"\1[REDACTED]@", msg)
            msg = _JWT.sub("[REDACTED_JWT]", msg)
            record.msg = _LABELLED.sub(r"\1[REDACTED]", msg)
            record.args = ()
        except Exception:  # pragma: no cover - logging must never raise
            pass
        return True


def setup_logging(level: str = "INFO") -> None:
    root = logging.getLogger()
    if not root.handlers:
        h = logging.StreamHandler()
        h.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s %(message)s"))
        h.addFilter(RedactFilter())
        root.addHandler(h)
    root.setLevel(level.upper())
