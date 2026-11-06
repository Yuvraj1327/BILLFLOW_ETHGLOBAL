"""FastAPI dependencies: current user (role from the DATABASE), RBAC, pagination, rate limiting."""
from __future__ import annotations

import time
from collections import defaultdict, deque
from dataclasses import dataclass
from typing import Annotated, Callable
from uuid import UUID

from fastapi import Depends, Query, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.core.config import Settings, get_settings
from app.core.database import transaction
from app.core.exceptions import AppError, forbidden, not_found, unauthorized
from app.core.security import verify_jwt
from app.repositories import profiles as prof

_bearer = HTTPBearer(auto_error=False, description="Supabase access token")


@dataclass(frozen=True)
class CurrentUser:
    id: UUID
    email: str | None
    role: str
    wallet_address: str | None
    display_name: str | None = None
    investor_verification: str | None = None


def current_user(creds: Annotated[HTTPAuthorizationCredentials | None, Depends(_bearer)],
                 settings: Annotated[Settings, Depends(get_settings)]) -> CurrentUser:
    if creds is None or creds.scheme.lower() != "bearer":
        raise unauthorized()
    claims = verify_jwt(creds.credentials, settings)
    cols = "id, email, role, wallet_address, display_name, investor_verification"
    with transaction() as c:
        row = c.execute(f"select {cols} from profiles where id = %s", (claims["sub"],)).fetchone()
        if row is None:  # the signup trigger did not run (or lagged): create the profile now, idempotently
            meta = claims.get("user_metadata") or {}
            prof.ensure(c, claims["sub"], claims.get("email"), meta.get("role"), meta.get("display_name"))
            row = c.execute(f"select {cols} from profiles where id = %s", (claims["sub"],)).fetchone()
    if row is None:
        raise unauthorized("This account no longer exists", "no_account")
    return CurrentUser(id=row["id"], email=row["email"], role=row["role"], wallet_address=row["wallet_address"],
                       display_name=row["display_name"], investor_verification=row["investor_verification"])


def require_roles(*roles: str) -> Callable[..., CurrentUser]:
    def dep(user: Annotated[CurrentUser, Depends(current_user)]) -> CurrentUser:
        if user.role not in roles:
            raise forbidden(f"Requires role: {', '.join(roles)}", "role_forbidden")
        return user
    return dep


Merchant = Annotated[CurrentUser, Depends(require_roles("merchant"))]
Admin = Annotated[CurrentUser, Depends(require_roles("admin"))]
Investor = Annotated[CurrentUser, Depends(require_roles("investor"))]
def verified_investor(user: Investor) -> CurrentUser:
    if user.investor_verification != "verified":
        raise forbidden("Your investor account has not been verified yet", "investor_not_verified")
    return user


VerifiedInvestor = Annotated[CurrentUser, Depends(verified_investor)]
AnyUser = Annotated[CurrentUser, Depends(current_user)]


@dataclass(frozen=True)
class BusinessCtx:
    user: CurrentUser
    business_id: UUID
    member_role: str  # owner | member


def current_business(user: Merchant) -> BusinessCtx:
    with transaction() as c:
        from app.repositories import businesses as biz  # local import: that module imports PageParams from here
        biz.ensure_business(c, user.id, user.display_name, user.email)  # no-op when a business exists
        row = c.execute(
            """select b.id, 'owner' as member_role from businesses b where b.owner_id = %s
               union all
               select m.business_id, m.member_role from business_members m where m.user_id = %s
               limit 1""", (user.id, user.id)).fetchone()
    if row is None:
        raise not_found("Business", "no_business")
    return BusinessCtx(user=user, business_id=row["id"], member_role=row["member_role"])


MerchantBiz = Annotated[BusinessCtx, Depends(current_business)]


@dataclass(frozen=True)
class PageParams:
    page: int
    page_size: int

    @property
    def offset(self) -> int:
        return (self.page - 1) * self.page_size


def page_params(page: int = Query(1, ge=1), page_size: int = Query(20, ge=1, le=100)) -> PageParams:
    return PageParams(page, page_size)


Pagination = Annotated[PageParams, Depends(page_params)]


def sort_clause(sort: str | None, order: str, allowed: dict[str, str], default: str) -> str:
    """Whitelisted ORDER BY (never interpolates user input)."""
    col = allowed.get(sort or "", allowed[default])
    return f"{col} {'asc' if order.lower() == 'asc' else 'desc'}"


# ── tiny in-process rate limiter for public endpoints (per client IP) ──
_hits: dict[str, deque] = defaultdict(deque)


def public_rate_limit(request: Request, settings: Annotated[Settings, Depends(get_settings)]) -> None:
    ip = request.client.host if request.client else "unknown"
    now = time.monotonic()
    if len(_hits) > 10_000:  # bound memory: drop IPs with no hit in the last minute
        for k in [k for k, d in _hits.items() if not d or now - d[-1] > 60]:
            del _hits[k]
    q = _hits[ip]
    while q and now - q[0] > 60:
        q.popleft()
    if len(q) >= settings.public_rate_limit_per_minute:
        raise AppError(429, "rate_limited", "Too many requests, slow down")
    q.append(now)


def reset_rate_limits() -> None:
    _hits.clear()
