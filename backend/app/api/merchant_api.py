"""Merchant tooling: API keys, webhooks, refunds, exports (JWT merchant) + the API-key checkout session API (server-to-server)."""
from __future__ import annotations

import csv
import io
import re
import time
from collections import defaultdict, deque
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Header, Query, Request, Response
from fastapi.responses import PlainTextResponse

from app.core.config import Settings, get_settings
from app.core.database import transaction
from app.core.dependencies import BusinessCtx, MerchantBiz, Pagination
from app.core.exceptions import AppError, not_found
from app.repositories import webhooks as wh_repo
from app.schemas.common import ERRORS, Message, Page
from app.schemas.merchant_api import ApiKeyIn, CheckoutSessionIn, RefundIn, RefundVerifyIn, WebhookIn
from app.services import checkout_service as co
from app.services import refund_service as rf
from app.services import webhook_service as wh
from app.core.dependencies import Merchant
from app.services._common import explorer_tx, money

Cfg = Annotated[Settings, Depends(get_settings)]

# ───────────────────────────── merchant dashboard endpoints (Supabase JWT, merchant role) ─────────────────────────────
router = APIRouter(prefix="/merchant", tags=["Merchant tools"], responses=ERRORS)


@router.post("/api-keys", status_code=201, summary="Create an API key (shown once)")
def create_key(body: ApiKeyIn, ctx: MerchantBiz):
    return co.create_key(ctx, body.name)


@router.get("/api-keys", summary="List API keys (prefix only)")
def list_keys(ctx: MerchantBiz):
    return co.list_keys(ctx)


@router.delete("/api-keys/{key_id}", response_model=Message, summary="Revoke an API key")
def revoke_key(key_id: UUID, ctx: MerchantBiz):
    co.revoke_key(ctx, key_id)
    return Message(message="revoked")


@router.post("/webhooks", status_code=201, summary="Register a webhook endpoint (signing secret shown once)")
def create_webhook(body: WebhookIn, ctx: MerchantBiz, s: Cfg):
    bad = [e for e in body.events if e != "*" and e not in wh.EVENT_TYPES]
    if bad:
        from app.core.exceptions import bad_request
        raise bad_request("invalid_events", f"Unknown events {bad}; allowed: {list(wh.EVENT_TYPES)} or '*'")
    wh.check_url(body.url, s)
    from app.core.security import new_opaque_token
    secret = "whsec_" + new_opaque_token(32)
    with transaction() as c:
        row = wh_repo.create_endpoint(c, ctx.business_id, body.url, secret, body.events or ["*"])
    return {"id": row["id"], "url": row["url"], "events": row["events"], "active": row["active"], "secret": secret,
            "note": "Store the secret now; it is used to verify the BillFlow-Signature header."}


@router.get("/webhooks", summary="List webhook endpoints")
def list_webhooks(ctx: MerchantBiz):
    with transaction() as c:
        return [{k: r[k] for k in ("id", "url", "events", "active", "created_at")} for r in wh_repo.list_endpoints(c, ctx.business_id)]


@router.delete("/webhooks/{endpoint_id}", response_model=Message, summary="Delete a webhook endpoint")
def delete_webhook(endpoint_id: UUID, ctx: MerchantBiz):
    with transaction() as c:
        if not wh_repo.delete_endpoint(c, ctx.business_id, endpoint_id):
            raise not_found("Webhook endpoint", "webhook_not_found")
    return Message(message="deleted")


@router.get("/webhook-deliveries", summary="Recent webhook deliveries and their status")
def deliveries(ctx: MerchantBiz):
    with transaction() as c:
        return wh_repo.list_deliveries(c, ctx.business_id)


@router.post("/webhook-deliveries/{delivery_id}/retry", response_model=Message, summary="Re-queue a FAILED delivery")
def retry_delivery(delivery_id: UUID, ctx: MerchantBiz):
    with transaction() as c:
        if not wh_repo.retry_failed(c, ctx.business_id, delivery_id):
            raise not_found("Failed delivery", "delivery_not_found")
    return Message(message="re-queued")


# ── refunds ──
@router.post("/payments/{payment_id}/refunds", status_code=201,
             summary="Prepare a full/partial refund; returns the approve+refund transactions your payout wallet must sign")
def prepare_refund(payment_id: UUID, body: RefundIn, ctx: MerchantBiz, s: Cfg):
    return rf.prepare(ctx, payment_id, body.amount, body.amount_base, body.reason, s)


@router.post("/refunds/verify", summary="Verify a refund transaction on-chain (hash supplied by the client is never trusted)")
def verify_refund(body: RefundVerifyIn, user: Merchant, s: Cfg):
    return rf.verify(user, body.tx_hash.lower(), s)


@router.get("/refunds", summary="My refunds")
def list_refunds(ctx: MerchantBiz, pg: Pagination, s: Cfg, status: str | None = Query(default=None, pattern="^(PENDING|CONFIRMED|CANCELLED)$")):
    rows, total = rf.list_(ctx, status, pg, s)
    return Page(items=rows, page=pg.page, page_size=pg.page_size, total=total)


@router.get("/refunds/{refund_id}", summary="One refund")
def get_refund(refund_id: UUID, ctx: MerchantBiz, s: Cfg):
    return rf.get(ctx, refund_id, s)


@router.get("/refunds/{refund_id}/chain-check", summary="Re-read the refund from the contract and compare with our record")
def refund_chain_check(refund_id: UUID, ctx: MerchantBiz, s: Cfg):
    return rf.chain_check(ctx, refund_id, s)


@router.post("/refunds/{refund_id}/cancel", summary="Withdraw a refund request that was never sent")
def cancel_refund(refund_id: UUID, ctx: MerchantBiz, s: Cfg):
    return rf.cancel_pending(ctx, refund_id, s)


# ── accountant export ──
_NUMBER = re.compile(r"^-?\d+(\.\d+)?$")


def _csv_cell(v) -> str:
    """Neutralise spreadsheet formula injection: text cells starting with = + - @ tab CR get a leading quote. Plain numbers
    (including negative refund amounts) are left alone so accountants can sum them."""
    t = "" if v is None else str(v)
    return "'" + t if t[:1] in ("=", "+", "-", "@", "\t", "\r") and not _NUMBER.match(t) else t


@router.get("/exports/payments.csv", response_class=PlainTextResponse, summary="Accountant export: payments and refunds with tx hashes")
def export_payments(ctx: MerchantBiz, s: Cfg, date_from: str | None = Query(default=None, pattern=r"^\d{4}-\d{2}-\d{2}$"),
                    date_to: str | None = Query(default=None, pattern=r"^\d{4}-\d{2}-\d{2}$")):
    with transaction() as c:
        rows = c.execute("""select 'payment' as kind, p.id, i.invoice_number, p.confirmed_at as at, p.payer_wallet as counterparty,
                                   p.amount_base as amount_base, i.token_decimals, i.currency, p.tx_hash, p.onchain_payment_id as onchain_id,
                                   (select reference from checkout_sessions cs where cs.invoice_id=i.id) as reference, null::text as refund_ref
                            from payments p join invoices i on i.id=p.invoice_id
                            where i.business_id=%(b)s and p.status='CONFIRMED'
                              and (%(f)s::date is null or p.confirmed_at >= %(f)s::date) and (%(t)s::date is null or p.confirmed_at < %(t)s::date + 1)
                            union all
                            select 'refund', r.id, i.invoice_number, r.refunded_at, p.payer_wallet, -r.amount_base, i.token_decimals, i.currency,
                                   r.tx_hash, r.onchain_refund_id, (select reference from checkout_sessions cs where cs.invoice_id=i.id), r.refund_ref
                            from refunds r join payments p on p.id=r.payment_id join invoices i on i.id=r.invoice_id
                            where r.business_id=%(b)s and r.status='CONFIRMED'
                              and (%(f)s::date is null or r.refunded_at >= %(f)s::date) and (%(t)s::date is null or r.refunded_at < %(t)s::date + 1)
                            order by 4""", {"b": ctx.business_id, "f": date_from, "t": date_to}).fetchall()
    buf = io.StringIO()
    w = csv.writer(buf, lineterminator="\n")
    w.writerow(["type", "id", "invoice_number", "reference", "confirmed_at_utc", "counterparty_wallet", "amount", "amount_base", "currency",
                "chain_id", "onchain_id", "refund_ref", "tx_hash", "explorer_url"])
    for r in rows:
        sign = "-" if int(r["amount_base"]) < 0 else ""
        w.writerow([_csv_cell(x) for x in (r["kind"], r["id"], r["invoice_number"], r["reference"], r["at"].isoformat() if r["at"] else "",
                                           r["counterparty"], sign + money(abs(int(r["amount_base"])), r["token_decimals"]), r["amount_base"],
                                           r["currency"], s.whitechain_chain_id, r["onchain_id"], r["refund_ref"], r["tx_hash"],
                                           explorer_tx(s, r["tx_hash"]))])
    return PlainTextResponse(buf.getvalue(), media_type="text/csv",
                             headers={"Content-Disposition": 'attachment; filename="billflow-payments.csv"'})


# ───────────────────────────── API-key authenticated checkout API (server-to-server) ─────────────────────────────
_hits: dict[str, deque] = defaultdict(deque)


def api_key_ctx(request: Request, s: Cfg, authorization: Annotated[str | None, Header()] = None,
                x_api_key: Annotated[str | None, Header()] = None) -> tuple[BusinessCtx, object]:
    raw = x_api_key or (authorization[7:].strip() if authorization and authorization.lower().startswith("bearer ") else None)
    auth = co.authenticate(raw)
    now, q = time.monotonic(), _hits[str(auth["api_key_id"])]
    while q and now - q[0] > 60:
        q.popleft()
    if len(q) >= s.api_key_rate_limit_per_minute:
        raise AppError(429, "rate_limited", "API key rate limit exceeded")
    q.append(now)
    return auth["ctx"], auth["api_key_id"]


KeyCtx = Annotated[tuple, Depends(api_key_ctx)]
checkout_router = APIRouter(prefix="/checkout", tags=["Checkout API (API key)"], responses=ERRORS)


@checkout_router.post("/sessions", status_code=201, summary="Create a checkout session (invoice + payment link) for one order")
def create_session(body: CheckoutSessionIn, k: KeyCtx, s: Cfg, idempotency_key: Annotated[str | None, Header()] = None):
    ctx, key_id = k
    return co.create_session(ctx, key_id, body, idempotency_key, s)


@checkout_router.get("/sessions/{session_id}", summary="Session status + receipts (paid status comes only from verified chain events)")
def get_session(session_id: UUID, k: KeyCtx, s: Cfg):
    return co.get_session(k[0], session_id, s)


@checkout_router.get("/sessions", summary="List sessions, optionally by your order reference")
def list_sessions(k: KeyCtx, s: Cfg, reference: str | None = Query(default=None, max_length=200), limit: int = Query(20, ge=1, le=100)):
    return co.list_sessions(k[0], reference, limit, s)


@checkout_router.post("/sessions/{session_id}/expire", summary="Cancel an unpaid session")
def expire_session(session_id: UUID, k: KeyCtx, s: Cfg):
    return co.expire_session(k[0], session_id, s)
