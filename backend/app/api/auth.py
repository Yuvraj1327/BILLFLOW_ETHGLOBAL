from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.core.config import Settings, get_settings
from app.core.dependencies import AnyUser
from app.core.exceptions import unauthorized
from app.schemas.auth import (LoginIn, RefreshIn, SessionOut, SignupIn, WalletChallengeIn, WalletChallengeOut, WalletVerifyIn)
from app.schemas.common import ERRORS, Message
from app.schemas.user import ProfileOut
from app.services import auth_service
from app.services.supabase_client import get_auth

router = APIRouter(prefix="/auth", tags=["Auth"], responses=ERRORS)
_bearer = HTTPBearer(auto_error=False)


def _session(d: dict) -> SessionOut:
    u = d.get("user") or d
    return SessionOut(access_token=d.get("access_token"), refresh_token=d.get("refresh_token"), expires_in=d.get("expires_in"),
                      user_id=u.get("id"), email=u.get("email"), confirmation_required=d.get("access_token") is None)


@router.post("/signup", response_model=SessionOut, status_code=201, summary="Create an account")
def signup(body: SignupIn) -> SessionOut:
    """`role` is only a request limited to merchant/investor; the database trigger enforces it and `admin` is never self-assignable.
    If the Supabase project requires e-mail confirmation no tokens are returned (`confirmation_required=true`)."""
    return _session(get_auth().signup(body.email, body.password, body.role, body.display_name))


@router.post("/login", response_model=SessionOut, summary="Log in with e-mail and password")
def login(body: LoginIn) -> SessionOut:
    return _session(get_auth().login(body.email, body.password))


@router.post("/refresh", response_model=SessionOut, summary="Exchange a refresh token")
def refresh(body: RefreshIn) -> SessionOut:
    return _session(get_auth().refresh(body.refresh_token))


@router.post("/logout", response_model=Message, summary="Revoke the current session")
def logout(creds: Annotated[HTTPAuthorizationCredentials | None, Depends(_bearer)], user: AnyUser) -> Message:
    if creds is None:
        raise unauthorized()
    get_auth().logout(creds.credentials)
    return Message(message="Logged out")


@router.get("/me", response_model=ProfileOut, summary="Current user (role comes from the database)")
def me(user: AnyUser) -> ProfileOut:
    from app.api.users import load_profile
    return load_profile(user.id)


@router.post("/wallet/challenge", response_model=WalletChallengeOut, summary="Start wallet-ownership proof")
def wallet_challenge(body: WalletChallengeIn, user: AnyUser, s: Annotated[Settings, Depends(get_settings)]):
    return auth_service.create_challenge(user.id, body.wallet_address, s)


@router.post("/wallet/verify", response_model=ProfileOut, summary="Link a wallet by signing the challenge (EIP-191)")
def wallet_verify(body: WalletVerifyIn, user: AnyUser, s: Annotated[Settings, Depends(get_settings)]):
    auth_service.verify_challenge(user.id, body.wallet_address, body.nonce, body.signature, s)
    from app.api.users import load_profile
    return load_profile(user.id)
