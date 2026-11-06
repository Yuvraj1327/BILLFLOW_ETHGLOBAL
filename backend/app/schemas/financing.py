from __future__ import annotations

from datetime import date, datetime
from typing import Any, Literal
from uuid import UUID

from pydantic import BaseModel, Field, model_validator

from app.schemas.common import Strict


class FinancingSubmit(Strict):
    invoice_id: UUID
    advance: str | None = Field(default=None, description="USDT to receive now, decimal string")
    advance_base: str | None = None
    debtor_wallet: str | None = Field(default=None, description="Expected payer address (optional; any payer may repay)")
    funding_window_hours: int | None = Field(default=None, ge=1, le=24 * 30)

    @model_validator(mode="after")
    def _one(self):
        if (self.advance is None) == (self.advance_base is None):
            raise ValueError("provide exactly one of `advance` or `advance_base`")
        return self


class DebtorAck(Strict):
    evidence_ref: str = Field(min_length=3, max_length=500, description="Reference to the debtor-acknowledgement evidence")
    acknowledged_at: datetime
    acknowledged_by: str | None = Field(default=None, max_length=200)
    document_sha256: str | None = Field(default=None, pattern=r"^[0-9a-fA-F]{64}$",
                                        description="SHA-256 of the debtor-acknowledgement document (file stays off-chain). "
                                                    "When given, this exact hash is anchored on-chain as debtorAckRef.")
    notes: str | None = Field(default=None, max_length=1000)


class AssignmentNotice(Strict):
    reference: str = Field(min_length=3, max_length=500)
    dated: date | None = None


class FinancingVerifyIn(Strict):
    decision: Literal["start_review", "approve", "reject"]
    notes: str | None = Field(default=None, max_length=2000)
    debtor_ack: DebtorAck | None = None
    assignment_notice: AssignmentNotice | None = None


class OfferOut(BaseModel):
    id: UUID
    invoice_id: UUID
    invoice_number: str
    business_id: UUID | None = None
    business_name: str | None = None
    business_verified: bool
    status: str
    display_status: str = Field(description="Product-brief label (SUBMITTED/VERIFIED/AVAILABLE/ACTIVE/OVERDUE...)")
    is_overdue: bool = False
    face_value: str
    face_value_base: str
    advance: str
    advance_base: str
    discount_bps: int
    token_decimals: int
    maturity_date: date
    days_to_maturity: int | None = Field(default=None, description="Maturity countdown; negative once overdue")
    funding_deadline: datetime
    onchain_offer_id: str | None
    onchain_registered_at: datetime | None = None
    onchain_verified_at: datetime | None = None
    contract_address: str | None = None
    debtor_ack: dict[str, Any] | None = None
    assignment_notice: dict[str, Any] | None = None
    review_notes: str | None = None
    created_at: datetime
    disclosure: str


class OnchainStep(BaseModel):
    step: str
    contract: str
    function: str
    signer: str
    args: dict[str, Any]
    note: str | None = None


class PublishOut(BaseModel):
    offer_id: UUID
    status: str
    chain_id: int
    next_step: OnchainStep | None
    remaining_steps: list[str]
    message: str


class InvestmentOut(BaseModel):
    id: UUID
    offer_id: UUID
    invoice_id: UUID
    invoice_number: str
    investor_wallet: str
    amount: str
    amount_base: str
    expected_repayment: str
    status: str
    offer_status: str
    maturity_date: date
    funded_at: datetime | None
    repayment_amount: str | None
    repayment_tx_hash: str | None
    settled_at: datetime | None
    tx_hash: str
    explorer_url: str


class FinancingOfferChainStatus(BaseModel):
    invoice_id: UUID
    offer: OfferOut | None
