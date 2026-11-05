from __future__ import annotations

from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, EmailStr, Field

from app.schemas.common import Strict


class BusinessCreate(Strict):
    legal_name: str = Field(min_length=2, max_length=200)
    country: str | None = Field(default=None, max_length=80)
    tax_id: str | None = Field(default=None, max_length=64)
    payout_wallet: str | None = Field(default=None, description="EVM address that receives USDT payments")


class BusinessUpdate(Strict):
    legal_name: str | None = Field(default=None, min_length=2, max_length=200)
    country: str | None = Field(default=None, max_length=80)
    tax_id: str | None = Field(default=None, max_length=64)
    payout_wallet: str | None = None


class BusinessOut(BaseModel):
    id: UUID
    owner_id: UUID
    legal_name: str
    country: str | None
    tax_id: str | None
    payout_wallet: str | None
    verification_status: str
    verified_at: datetime | None
    created_at: datetime


class MemberAdd(Strict):
    email: EmailStr


class MemberOut(BaseModel):
    user_id: UUID
    email: str | None
    display_name: str | None
    member_role: str
    created_at: datetime


class CustomerCreate(Strict):
    name: str = Field(min_length=1, max_length=200)
    email: EmailStr | None = None
    wallet_address: str | None = None


class CustomerUpdate(Strict):
    name: str | None = Field(default=None, min_length=1, max_length=200)
    email: EmailStr | None = None
    wallet_address: str | None = None


class CustomerOut(BaseModel):
    id: UUID
    business_id: UUID
    name: str
    email: str | None
    wallet_address: str | None
    archived_at: datetime | None
    created_at: datetime
