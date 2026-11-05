"""JWT verification (Supabase) and opaque-token helpers."""
from __future__ import annotations

import secrets
from typing import Any

import jwt
from jwt import PyJWKClient

from app.core.config import Settings
from app.core.exceptions import unauthorized

_ASYMMETRIC = {"RS256", "ES256", "EdDSA", "RS384", "RS512", "ES384", "ES512"}
_jwks_clients: dict[str, PyJWKClient] = {}


def _jwks(url: str) -> PyJWKClient:
    if url not in _jwks_clients:
        _jwks_clients[url] = PyJWKClient(url, cache_keys=True, lifespan=3600)
    return _jwks_clients[url]


def verify_jwt(token: str, s: Settings) -> dict[str, Any]:
    """Verify a Supabase access token. Rejects `none`, unknown algorithms, wrong audience, expired tokens.

    Roles inside the token are NEVER used for authorisation; only `sub`/`email` are read.
    """
    try:
        alg = jwt.get_unverified_header(token).get("alg", "")
    except jwt.PyJWTError:
        raise unauthorized("Invalid token", "invalid_token")
    try:
        if alg == "HS256":
            if not s.supabase_jwt_secret:
                raise unauthorized("Invalid token", "invalid_token")
            key: Any = s.supabase_jwt_secret
        elif alg in _ASYMMETRIC:
            if not s.supabase_jwt_jwks_url:
                raise unauthorized("Invalid token", "invalid_token")
            key = _jwks(s.supabase_jwt_jwks_url).get_signing_key_from_jwt(token).key
        else:
            raise unauthorized("Invalid token", "invalid_token")
        claims = jwt.decode(token, key, algorithms=[alg], audience=s.supabase_jwt_audience,
                            options={"require": ["exp", "sub"]})
    except jwt.ExpiredSignatureError:
        raise unauthorized("Token expired", "token_expired")
    except jwt.PyJWTError:
        raise unauthorized("Invalid token", "invalid_token")
    return claims


def new_opaque_token(nbytes: int = 32) -> str:
    """Unguessable URL-safe token (256 bits)."""
    return secrets.token_urlsafe(nbytes)


def random_uint256() -> int:
    return secrets.randbits(256)
