"""Supabase GoTrue (auth) and Storage over REST. The service-role key is used ONLY here, server-side.

Both are hidden behind small classes so tests can substitute fakes (`set_supabase`, `set_storage`).
"""
from __future__ import annotations

import logging
from typing import Any, Protocol

import httpx

from app.core.config import Settings, get_settings
from app.core.exceptions import AppError, unauthorized, upstream

log = logging.getLogger("billflow.supabase")


class AuthClient(Protocol):
    def signup(self, email: str, password: str, role: str, display_name: str | None) -> dict[str, Any]: ...
    def login(self, email: str, password: str) -> dict[str, Any]: ...
    def refresh(self, refresh_token: str) -> dict[str, Any]: ...
    def logout(self, access_token: str) -> None: ...
    def admin_create_user(self, email: str, password: str, display_name: str | None) -> dict[str, Any]: ...


class StorageClient(Protocol):
    def upload(self, path: str, data: bytes, content_type: str) -> None: ...
    def download(self, path: str) -> bytes: ...
    def signed_url(self, path: str, expires_in: int = 300) -> str: ...
    def remove(self, path: str) -> None: ...


class GoTrue:
    def __init__(self, s: Settings):
        if not s.supabase_url or not s.supabase_anon_key:
            raise AppError(503, "supabase_not_configured", "SUPABASE_URL / SUPABASE_ANON_KEY are not configured")
        self.base = s.supabase_url.rstrip("/") + "/auth/v1"
        self.anon = s.supabase_anon_key

    def _post(self, path: str, json: dict, params: dict | None = None, token: str | None = None) -> httpx.Response:
        h = {"apikey": self.anon, "Authorization": f"Bearer {token or self.anon}"}
        try:
            return httpx.post(self.base + path, json=json, params=params, headers=h, timeout=15)
        except httpx.HTTPError as e:
            raise upstream("supabase_unavailable", f"Auth provider unreachable: {type(e).__name__}") from e

    @staticmethod
    def _fail(r: httpx.Response, code: str) -> AppError:
        msg = "Authentication failed"
        try:
            body = r.json()
            if body.get("error_code") in ("email_exists", "user_already_exists"):
                return AppError(409, "email_exists", "An account with this email already exists. Log in instead.")
            msg = body.get("msg") or body.get("error_description") or body.get("message") or msg
        except Exception:  # noqa: BLE001
            pass
        status = r.status_code if r.status_code in (400, 401, 403, 422, 429) else 502
        return AppError(401 if status in (400, 401) and code != "signup_failed" else status, code, msg)

    def signup(self, email, password, role, display_name):
        # `role` is only a *request*: the DB trigger clamps it to merchant/investor/customer. admin is impossible here.
        s = get_settings()
        if not s.is_production and s.supabase_service_role_key:
            # Development: create the user already e-mail-confirmed and log straight in (no confirmation step).
            self.admin_create_user(email, password, display_name, role=role)
            return self.login(email, password)
        r = self._post("/signup", {"email": email, "password": password,
                                   "data": {"role": role, "display_name": display_name}})
        if r.status_code >= 400:
            raise self._fail(r, "signup_failed")
        return r.json()

    def login(self, email, password):
        r = self._post("/token", {"email": email, "password": password}, params={"grant_type": "password"})
        if r.status_code >= 400:
            raise unauthorized("Invalid email or password", "invalid_credentials")
        return r.json()

    def refresh(self, refresh_token):
        r = self._post("/token", {"refresh_token": refresh_token}, params={"grant_type": "refresh_token"})
        if r.status_code >= 400:
            raise unauthorized("Refresh token is invalid or expired", "invalid_refresh_token")
        return r.json()

    def logout(self, access_token):
        r = self._post("/logout", {}, token=access_token)
        if r.status_code >= 500:
            raise upstream("supabase_unavailable", "Auth provider error")


    def admin_create_user(self, email, password, display_name, role=None):
        """Service-role call: creates an e-mail-confirmed user. Never reachable from the public signup path."""
        key = get_settings().supabase_service_role_key
        if not key:
            raise AppError(503, "supabase_not_configured", "SUPABASE_SERVICE_ROLE_KEY is not configured")
        try:
            r = httpx.post(self.base + "/admin/users", headers={"apikey": key, "Authorization": f"Bearer {key}"}, timeout=15,
                           json={"email": email, "password": password, "email_confirm": True,
                                 "user_metadata": {"display_name": display_name, **({"role": role} if role else {})}})
        except httpx.HTTPError as e:
            raise upstream("supabase_unavailable", f"Auth provider unreachable: {type(e).__name__}") from e
        if r.status_code >= 400:
            raise self._fail(r, "signup_failed")
        return r.json()


class SupabaseStorage:
    def __init__(self, s: Settings):
        if not s.supabase_url or not s.supabase_service_role_key:
            raise AppError(503, "storage_not_configured", "SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are not configured")
        self.base = s.supabase_url.rstrip("/") + "/storage/v1"
        self.bucket = s.supabase_storage_bucket
        self.h = {"apikey": s.supabase_service_role_key, "Authorization": f"Bearer {s.supabase_service_role_key}"}

    def _req(self, method: str, path: str, **kw) -> httpx.Response:
        try:
            return httpx.request(method, self.base + path, headers={**self.h, **kw.pop("headers", {})}, timeout=30, **kw)
        except httpx.HTTPError as e:
            raise upstream("storage_unavailable", f"Storage unreachable: {type(e).__name__}") from e

    def upload(self, path, data, content_type):
        r = self._req("POST", f"/object/{self.bucket}/{path}", content=data,
                      headers={"Content-Type": content_type, "x-upsert": "false"})
        if r.status_code >= 400:
            raise upstream("storage_upload_failed", f"Storage rejected the upload ({r.status_code})")

    def download(self, path):
        r = self._req("GET", f"/object/{self.bucket}/{path}")
        if r.status_code >= 400:
            raise upstream("storage_download_failed", f"Storage download failed ({r.status_code})")
        return r.content

    def signed_url(self, path, expires_in=300):
        r = self._req("POST", f"/object/sign/{self.bucket}/{path}", json={"expiresIn": expires_in})
        if r.status_code >= 400:
            raise upstream("storage_sign_failed", f"Could not sign URL ({r.status_code})")
        return self.base.removesuffix("/storage/v1") + "/storage/v1" + r.json()["signedURL"]

    def remove(self, path):
        self._req("DELETE", f"/object/{self.bucket}/{path}")


_auth: AuthClient | None = None
_storage: StorageClient | None = None


def set_supabase(client: AuthClient | None) -> None:
    global _auth
    _auth = client


def set_storage(client: StorageClient | None) -> None:
    global _storage
    _storage = client


def get_auth() -> AuthClient:
    return _auth or GoTrue(get_settings())


def get_storage() -> StorageClient:
    return _storage or SupabaseStorage(get_settings())
