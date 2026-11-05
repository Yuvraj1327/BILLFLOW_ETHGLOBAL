from __future__ import annotations

from datetime import date, datetime
from typing import Any

from pydantic import BaseModel, Field

from app.schemas.common import Strict


class PublicInvoiceOut(BaseModel):
    merchant_name: str
    invoice_number: str
    description: str | None
    amount: str
    paid_amount: str
    remaining_amount: str
    currency: str
    due_date: date
    status: str
    payable: bool
    payable_reason: str | None
    chain_id: int
    usdt_address: str
    usdt_decimals: int
    payments_contract: str
    link_expires_at: datetime | None


class PaymentIntentIn(Strict):
    payer_wallet: str
    amount: str | None = Field(default=None, description="Partial amount (USDT). Defaults to the full remaining amount.")


class PaymentIntentOut(BaseModel):
    chain_id: int
    payments_contract: str
    usdt_address: str
    usdt_decimals: int
    approve_amount_base: str
    quote: dict[str, Any]
    signature: str
    quote_expires_at: datetime
    eip712_domain: dict[str, Any]
    instructions: str


class PublicStatusOut(BaseModel):
    status: str
    amount: str
    paid_amount: str
    remaining_amount: str
    payable: bool
    payments: list[dict[str, Any]]
