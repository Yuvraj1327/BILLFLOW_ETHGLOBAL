from __future__ import annotations

from typing import Any

from pydantic import Field, field_validator

from app.schemas.common import Strict


class CheckoutCustomer(Strict):
    name: str | None = Field(default=None, max_length=200)
    email: str | None = Field(default=None, max_length=320)


class CheckoutSessionIn(Strict):
    amount: str = Field(description="Decimal USDT amount, e.g. '25.50'")
    description: str | None = Field(default=None, max_length=1000)
    reference: str | None = Field(default=None, max_length=200, description="Your own order id; echoed in webhooks")
    customer: CheckoutCustomer | None = None
    metadata: dict[str, Any] = Field(default_factory=dict)
    success_url: str | None = None
    cancel_url: str | None = None
    due_in_days: int = Field(default=7, ge=0, le=365)

    @field_validator("metadata")
    @classmethod
    def _small(cls, v: dict) -> dict:
        import json
        if len(v) > 20 or len(json.dumps(v)) > 4000:
            raise ValueError("metadata is limited to 20 keys / 4 KB")
        return v


class ApiKeyIn(Strict):
    name: str = Field(min_length=1, max_length=80)


class WebhookIn(Strict):
    url: str = Field(max_length=2000)
    events: list[str] = Field(default_factory=lambda: ["*"])


class RefundIn(Strict):
    amount: str | None = Field(default=None, description="Decimal USDT; omit and send amount_base for exact base units")
    amount_base: str | None = Field(default=None, pattern=r"^[0-9]{1,38}$")
    reason: str | None = Field(default=None, max_length=1000)


class RefundVerifyIn(Strict):
    tx_hash: str = Field(pattern=r"^0x[0-9a-fA-F]{64}$")
