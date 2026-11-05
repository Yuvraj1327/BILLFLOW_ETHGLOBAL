from __future__ import annotations

from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, Field

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
