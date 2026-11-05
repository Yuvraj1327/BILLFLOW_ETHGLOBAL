from __future__ import annotations

from datetime import datetime
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, EmailStr, Field

from app.schemas.common import Strict


class SignupIn(Strict):
    email: EmailStr
    password: str = Field(min_length=8, max_length=128)
    role: Literal["merchant", "investor"] = Field(description="Requested role. 'customer' is the default; 'admin' can never be self-assigned.")
    display_name: str | None = Field(default=None, max_length=120)


class LoginIn(Strict):
    email: EmailStr
    password: str = Field(min_length=1, max_length=128)


class RefreshIn(Strict):
    refresh_token: str = Field(min_length=10)


class SessionOut(BaseModel):
    access_token: str | None = None
    refresh_token: str | None = None
    token_type: str = "bearer"
    expires_in: int | None = None
    user_id: UUID | None = None
    email: str | None = None
    confirmation_required: bool = False


class WalletChallengeIn(Strict):
    wallet_address: str


class WalletChallengeOut(BaseModel):
    nonce: str
    message: str
    expires_at: datetime


class WalletVerifyIn(Strict):
    wallet_address: str
    nonce: str
    signature: str
