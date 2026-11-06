"""Merchant API keys + checkout sessions (the server-side half of the embeddable BillFlow checkout).

A checkout session = one invoice + one payment link, created through the same invoice service the dashboard uses, so every
payment-safety rule (on-chain invoice id/hash, payable checks, quotes, verification-only status changes) is inherited unchanged.
"""
from __future__ import annotations

import hashlib
import logging
import re
from datetime import date, timedelta
from types import SimpleNamespace
from urllib.parse import urlsplit
from uuid import UUID, uuid4

import psycopg.errors
from psycopg.types.json import Jsonb

from app.core.config import Settings
from app.core.database import transaction
from app.core.dependencies import BusinessCtx, CurrentUser
from app.core.exceptions import bad_request, conflict, not_found, unauthorized
from app.core.security import new_opaque_token
from app.repositories import businesses as biz_repo
from app.repositories import invoices as inv_repo
from app.repositories import payments as pay_repo
from app.repositories import refunds as refund_repo
from app.repositories import webhooks as wh_repo
from app.repositories.system import audit
from app.services import invoice_service
from app.services._common import explorer_tx, money

log = logging.getLogger("billflow.checkout")
KEY_PREFIX = "bf_test_"  # testnet keys only; there is no live-mode key


def _hash(key: str) -> str:
    return hashlib.sha256(key.encode()).hexdigest()


# ───────────────────────── API keys ─────────────────────────
def create_key(ctx: BusinessCtx, name: str) -> dict:
    key = KEY_PREFIX + new_opaque_token(32)
    with transaction() as c:
        row = wh_repo.create_key(c, ctx.business_id, name, key[:12], _hash(key), ctx.user.id)
        audit(c, ctx.user.id, "api_key_created", "api_key", row["id"], {"name": name})
    return {"id": row["id"], "name": name, "key": key, "key_prefix": key[:12], "created_at": row["created_at"],
            "note": "Store this key now; only its hash is kept and it cannot be shown again."}


def list_keys(ctx: BusinessCtx) -> list[dict]:
    with transaction() as c:
        return wh_repo.list_keys(c, ctx.business_id)


def revoke_key(ctx: BusinessCtx, key_id) -> None:
    with transaction() as c:
        if not wh_repo.revoke_key(c, ctx.business_id, key_id):
            raise not_found("API key", "api_key_not_found")
        audit(c, ctx.user.id, "api_key_revoked", "api_key", key_id)


def authenticate(raw: str | None) -> dict:
    """Resolve a presented key to {api_key_id, business_id, owner_id}. Same error for unknown / revoked keys."""
    if not raw or not raw.startswith(KEY_PREFIX) or len(raw) > 200:
        raise unauthorized("A valid API key is required", "invalid_api_key")
    with transaction() as c:
        k = wh_repo.key_by_hash(c, _hash(raw))
        if k is None or k["revoked_at"] is not None:
            raise unauthorized("A valid API key is required", "invalid_api_key")
        wh_repo.touch_key(c, k["id"])
        b = c.execute("select id, owner_id from businesses where id=%s", (k["business_id"],)).fetchone()
        owner = c.execute("select id, email, role, wallet_address, display_name from profiles where id=%s", (b["owner_id"],)).fetchone()
    ctx = BusinessCtx(user=CurrentUser(id=owner["id"], email=owner["email"], role=owner["role"],
                                       wallet_address=owner["wallet_address"], display_name=owner["display_name"]),
                      business_id=b["id"], member_role="owner")
    return {"api_key_id": k["id"], "ctx": ctx}


# ───────────────────────── sessions ─────────────────────────
def _safe_url(u: str | None, field: str) -> str | None:
    if u is None:
        return None
    p = urlsplit(u)
    if p.scheme not in ("http", "https") or not p.hostname or len(u) > 2000 or p.username or p.password:
        raise bad_request("invalid_url", f"{field} must be an absolute http(s) URL")
    return u


def _view(c, inv: dict, sess: dict, s: Settings) -> dict:
    d = inv["token_decimals"]
    pays = pay_repo.for_invoice(c, inv["id"])
    link = inv_repo.active_link(c, inv["id"])
    total, paid = int(inv["amount_base"]), int(inv["paid_amount_base"])
    refunded = sum(int(p["refunded_amount_base"]) for p in pays)
    if inv["status"] == "PAID":
        state = "refunded" if refunded and refunded >= paid else "paid"
    else:
        state = {"PARTIALLY_PAID": "partially_paid", "CANCELLED": "cancelled", "OVERDUE": "open", "PENDING": "open"}.get(inv["status"], inv["status"].lower())
    receipts = []
    for p in pays:
        refs = [refund_repo.get(c, r["id"]) for r in refund_repo.for_payment(c, p["id"])]
        receipts.append({"payment_id": p["id"], "amount": money(p["amount_base"], d), "amount_base": str(int(p["amount_base"])),
                         "currency": inv["currency"], "payer_wallet": p["payer_wallet"], "tx_hash": p["tx_hash"],
                         "explorer_url": explorer_tx(s, p["tx_hash"]), "confirmed_at": p["confirmed_at"], "chain_id": s.whitechain_chain_id,
                         "refunded": money(p["refunded_amount_base"], d),
                         "refunds": [{"id": r["id"], "amount": money(r["amount_base"], d), "status": r["status"], "tx_hash": r["tx_hash"],
                                      "explorer_url": explorer_tx(s, r["tx_hash"])} for r in refs]})
    return {"id": sess["id"], "invoice_id": inv["id"], "invoice_number": inv["invoice_number"], "reference": sess["reference"],
            "metadata": sess["metadata"], "status": state, "amount": money(total, d), "paid_amount": money(paid, d),
            "remaining_amount": money(total - paid, d), "currency": inv["currency"], "success_url": sess["success_url"],
            "cancel_url": sess["cancel_url"], "checkout_url": f"{s.public_checkout_base_url.rstrip('/')}/pay/{link['token']}" if link else None,
            "link_expires_at": link["expires_at"] if link else None, "receipts": receipts, "created_at": sess["created_at"]}


def create_session(ctx: BusinessCtx, api_key_id, body, idempotency_key: str | None, s: Settings) -> dict:
    if idempotency_key is not None and not re.fullmatch(r"[A-Za-z0-9_\-:.]{8,100}", idempotency_key):
        raise bad_request("invalid_idempotency_key", "Idempotency-Key must be 8-100 chars of [A-Za-z0-9_-:.]")
    success, cancel = _safe_url(body.success_url, "success_url"), _safe_url(body.cancel_url, "cancel_url")
    if idempotency_key:
        with transaction() as c:
            prior = c.execute("select * from checkout_sessions where business_id=%s and idempotency_key=%s",
                              (ctx.business_id, idempotency_key)).fetchone()
            if prior:
                return _view(c, inv_repo.get(c, prior["invoice_id"]), prior, s)
    with transaction() as c:
        cust_in = body.customer
        cust = None
        if cust_in and cust_in.email:
            cust = c.execute("select * from customers where business_id=%s and lower(email)=lower(%s) and archived_at is null limit 1",
                             (ctx.business_id, cust_in.email)).fetchone()
        if cust is None:
            cust = biz_repo.create_customer(c, ctx.business_id, {"name": (cust_in.name if cust_in and cust_in.name else "Checkout customer"),
                                                                 "email": cust_in.email if cust_in else None, "wallet_address": None})
    today = date.today()
    number = f"CHK-{today:%Y%m%d}-{uuid4().hex[:8].upper()}"
    inv = invoice_service.create(ctx, SimpleNamespace(
        customer_id=cust["id"], invoice_number=number, description=body.description, amount=body.amount, amount_base=None,
        issue_date=today, due_date=today + timedelta(days=body.due_in_days), issue=True), s)
    link = invoice_service.create_payment_link(ctx, inv["id"], s)
    try:
        with transaction() as c:
            sess = c.execute("""insert into checkout_sessions (business_id, invoice_id, reference, metadata, success_url, cancel_url,
                                idempotency_key, api_key_id) values (%s,%s,%s,%s,%s,%s,%s,%s) returning *""",
                             (ctx.business_id, inv["id"], body.reference, Jsonb(body.metadata), success, cancel, idempotency_key,
                              api_key_id)).fetchone()
            audit(c, ctx.user.id, "checkout_session_created", "invoice", inv["id"], {"reference": body.reference})
            out = _view(c, inv_repo.get(c, inv["id"]), sess, s)
    except psycopg.errors.UniqueViolation:  # concurrent request with the same Idempotency-Key
        with transaction() as c:
            prior = c.execute("select * from checkout_sessions where business_id=%s and idempotency_key=%s",
                              (ctx.business_id, idempotency_key)).fetchone()
            if not prior:
                raise
            return _view(c, inv_repo.get(c, prior["invoice_id"]), prior, s)
    out["checkout_url"] = link["url"]
    return out


def get_session(ctx: BusinessCtx, session_id, s: Settings) -> dict:
    with transaction() as c:
        sess = c.execute("select * from checkout_sessions where id=%s and business_id=%s", (session_id, ctx.business_id)).fetchone()
        if sess is None:
            raise not_found("Checkout session", "session_not_found")
        return _view(c, inv_repo.get(c, sess["invoice_id"]), sess, s)


def list_sessions(ctx: BusinessCtx, reference: str | None, limit: int, s: Settings) -> list[dict]:
    with transaction() as c:
        rows = c.execute("""select * from checkout_sessions where business_id=%s and (%s::text is null or reference=%s)
                            order by created_at desc limit %s""", (ctx.business_id, reference, reference, limit)).fetchall()
        return [_view(c, inv_repo.get(c, r["invoice_id"]), r, s) for r in rows]


def expire_session(ctx: BusinessCtx, session_id, s: Settings) -> dict:
    with transaction() as c:
        sess = c.execute("select * from checkout_sessions where id=%s and business_id=%s", (session_id, ctx.business_id)).fetchone()
    if sess is None:
        raise not_found("Checkout session", "session_not_found")
    invoice_service.cancel(ctx, sess["invoice_id"], "checkout session expired by merchant", s)
    return get_session(ctx, session_id, s)


def session_for_invoice(c, invoice_id) -> dict | None:
    return c.execute("select id, reference, success_url, cancel_url from checkout_sessions where invoice_id=%s", (invoice_id,)).fetchone()
