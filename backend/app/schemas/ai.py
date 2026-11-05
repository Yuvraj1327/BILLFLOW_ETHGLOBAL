from __future__ import annotations

from datetime import date
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field


class ExtractedInvoice(BaseModel):
    """Strict schema every Claude extraction must satisfy. Unknown keys are rejected."""
    model_config = ConfigDict(extra="forbid")

    invoice_number: str | None = Field(default=None, max_length=100)
    merchant_name: str | None = Field(default=None, max_length=300)
    merchant_address: str | None = Field(default=None, max_length=500)
    customer_name: str | None = Field(default=None, max_length=300)
    customer_address: str | None = Field(default=None, max_length=500)
    amount: str | None = Field(default=None, pattern=r"^\d+(\.\d+)?$", description="Total payable as a plain decimal string")
    currency: str | None = Field(default=None, max_length=10)
    description: str | None = Field(default=None, max_length=2000)
    issue_date: date | None = None
    due_date: date | None = None
    tax_amount: str | None = Field(default=None, pattern=r"^\d+(\.\d+)?$")
    tax_id: str | None = Field(default=None, max_length=100)
    confidence: float = Field(ge=0, le=1, description="Overall extraction confidence")
    field_confidence: dict[str, float] = Field(default_factory=dict)
    warnings: list[str] = Field(default_factory=list, max_length=20)


class ExtractionOut(BaseModel):
    extracted: ExtractedInvoice
    sha256: str
    document_hash: str
    pages: int | None
    duplicate_warnings: list[str] = []
    notice: str = "AI extraction is not legal verification. Review every field before use."


class InvoiceRef(BaseModel):
    invoice_id: UUID


class AiSummary(BaseModel):
    model_config = ConfigDict(extra="forbid")
    summary: str = Field(max_length=2000)
    status_explanation: str = Field(max_length=1000)
    missing_fields: list[str] = Field(default_factory=list, max_length=20)
    suggested_category: str | None = Field(default=None, max_length=80)


class SummaryOut(AiSummary):
    notice: str = "AI-generated summary; not a financial or legal opinion."


class ReminderIn(BaseModel):
    invoice_id: UUID
    tone: Literal["friendly", "neutral", "firm"] = "neutral"


class AiReminder(BaseModel):
    model_config = ConfigDict(extra="forbid")
    subject: str = Field(max_length=200)
    body: str = Field(max_length=2000)


class ReminderOut(AiReminder):
    notice: str = "Draft only. Nothing is sent automatically."


class AiValidation(BaseModel):
    model_config = ConfigDict(extra="forbid")
    warnings: list[str] = Field(default_factory=list, max_length=30)
    confidence: float = Field(ge=0, le=1)


class ValidationOut(BaseModel):
    invoice_id: UUID
    issues: list[str]
    duplicate_warnings: list[str]
    ai_warnings: list[str]
    confidence: float
    ai_used: bool
    notice: str = "Advisory only. AI validation never approves an invoice or financing."
