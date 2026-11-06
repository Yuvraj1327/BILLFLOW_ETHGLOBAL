from __future__ import annotations

from datetime import datetime
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, EmailStr, Field

from app.schemas.common import Strict


class ProfileOut(BaseModel):
    id: UUID
    email: str | None
    role: str
    display_name: str | None
    wallet_address: str | None
    investor_verification: str
    business_id: UUID | None = None
    created_at: datetime


class ProfileUpdate(Strict):
    display_name: str | None = Field(default=None, max_length=120)


class RoleUpdate(Strict):
    role: str = Field(pattern="^(merchant|customer|investor|admin)$")


class InvestorOnboardingIn(Strict):
    full_name: str = Field(min_length=2, max_length=160)
    country: str = Field(min_length=2, max_length=80)
    investor_type: Literal["individual", "institution"]
    organization: str | None = Field(default=None, max_length=160)
    tax_id: str | None = Field(default=None, max_length=80)
    accept_terms: bool
    accept_risk: bool


class InvestorOnboardingOut(BaseModel):
    full_name: str
    country: str
    investor_type: str
    organization: str | None = None
    tax_id: str | None = None
    submitted_at: datetime
    review_notes: str | None = None
    verification: str


class AdminCreateIn(Strict):
    email: EmailStr
    password: str = Field(min_length=12, max_length=128)
    display_name: str | None = Field(default=None, max_length=120)
