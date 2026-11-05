from __future__ import annotations

from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, Field

from app.schemas.common import Strict

TX_HASH = r"^0x[0-9a-fA-F]{64}$"


class VerifyTxIn(Strict):
    tx_hash: str = Field(pattern=TX_HASH)


class PaymentOut(BaseModel):
    id: UUID
    invoice_id: UUID
    invoice_number: str | None = None
    payer_wallet: str
    amount: str
    amount_base: str
    tx_hash: str
    log_index: int
    block_number: int | None
    status: str
    confirmed_at: datetime | None
    explorer_url: str


class TxVerificationOut(BaseModel):
    tx_hash: str
    stage: str = Field(description="not_found | submitted | failed | confirmed | rejected | verified")
    detail: str = ""
    confirmations: int
    required_confirmations: int
    block_number: int | None
    explorer_url: str
    events: list[dict]
    payment_ids: list[str] = []
    offer_ids: list[str] = []
