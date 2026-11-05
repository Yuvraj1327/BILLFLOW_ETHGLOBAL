from __future__ import annotations

from datetime import date, datetime
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, Field, model_validator

from app.schemas.common import Strict


class InvoiceCreate(Strict):
    customer_id: UUID
    invoice_number: str = Field(min_length=1, max_length=64)
    description: str | None = Field(default=None, max_length=2000)
    amount: str | None = Field(default=None, description="Decimal string in whole USDT, e.g. '1000.50'")
    amount_base: str | None = Field(default=None, description="Integer token base units (alternative to `amount`)")
    currency: Literal["USDT"] = "USDT"
    issue_date: date | None = None
    due_date: date
    issue: bool = Field(default=False, description="Issue immediately (DRAFT -> PENDING)")

    @model_validator(mode="after")
    def _one_amount(self):
        if (self.amount is None) == (self.amount_base is None):
            raise ValueError("provide exactly one of `amount` or `amount_base`")
        return self


class InvoiceUpdate(Strict):
    customer_id: UUID | None = None
    invoice_number: str | None = Field(default=None, min_length=1, max_length=64)
    description: str | None = Field(default=None, max_length=2000)
    amount: str | None = None
    amount_base: str | None = None
    issue_date: date | None = None
    due_date: date | None = None

    @model_validator(mode="after")
    def _not_both(self):
        if self.amount is not None and self.amount_base is not None:
            raise ValueError("provide only one of `amount` or `amount_base`")
        return self


class InvoiceOut(BaseModel):
    id: UUID
    merchant_id: UUID = Field(description="Business id of the issuer")
    customer_id: UUID
    customer_name: str | None = None
    invoice_number: str
    description: str | None
    amount: str
    amount_base: str
    token_decimals: int
    currency: str
    issue_date: date
    due_date: date
    status: str
    paid_amount: str
    paid_amount_base: str
    review_status: str
    onchain_invoice_id: str | None
    invoice_hash: str | None
    document_hash: str | None = None
    payment_tx_hash: str | None = None
    payment_explorer_url: str | None = None
    financing_status: str | None = None
    financing_offer_id: UUID | None = None
    created_at: datetime
    updated_at: datetime


class DocumentOut(BaseModel):
    id: UUID
    invoice_id: UUID | None
    sha256: str
    document_hash: str
    size_bytes: int
    mime_type: str
    created_at: datetime
    duplicate_warnings: list[str] = []


class PaymentLinkOut(BaseModel):
    id: UUID
    token: str
    url: str
    expires_at: datetime | None


class PaymentRecord(BaseModel):
    id: UUID
    payer_wallet: str
    amount: str
    amount_base: str
    tx_hash: str
    explorer_url: str
    status: str
    confirmed_at: datetime | None


class PaymentStatusOut(BaseModel):
    invoice_id: UUID
    status: str
    amount: str
    paid_amount: str
    remaining_amount: str
    payments: list[PaymentRecord]
    financing_status: str | None
    payable: bool
    payable_reason: str | None = None
