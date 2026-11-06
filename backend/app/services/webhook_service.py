"""Signed webhooks with retry. Events are enqueued in the SAME transaction that applies the verified chain event, so a webhook
is only ever created for something the backend verified on-chain (never from a client's claim), and `unique(endpoint, event_id)`
makes enqueueing idempotent.

Signature: header `BillFlow-Signature: t=<unix>,v1=<hex hmac_sha256(secret, f"{t}.{raw_body}")>`. Receivers must verify the HMAC
with a constant-time compare and reject timestamps older than ~5 minutes (replay protection).
Delivery is at-least-once: receivers must dedupe on the event `id`.
"""
from __future__ import annotations

import hashlib
import hmac
import ipaddress
import json
import logging
import socket
import time
from datetime import datetime, timezone
from urllib.parse import urlsplit

import httpx
from psycopg import Connection

from app.core.config import Settings
from app.core.database import transaction
from app.core.exceptions import bad_request
from app.repositories import webhooks as repo
from app.services._common import explorer_tx, money

log = logging.getLogger("billflow.webhooks")
EVENT_TYPES = ("payment.confirmed", "invoice.paid", "refund.confirmed")
BACKOFF = (30, 120, 600, 3600, 6 * 3600)  # seconds after attempt 1..5


def sign(secret: str, timestamp: int, body: str) -> str:
    return hmac.new(secret.encode(), f"{timestamp}.{body}".encode(), hashlib.sha256).hexdigest()


def verify_signature(secret: str, header: str, body: str, tolerance: int = 300, now: int | None = None) -> bool:
    """Reference verifier (also what the demo merchant implements)."""
    try:
        parts = dict(p.split("=", 1) for p in header.split(","))
        t, v1 = int(parts["t"]), parts["v1"]
    except (KeyError, ValueError):
        return False
    if abs((now or int(time.time())) - t) > tolerance:
        return False
    return hmac.compare_digest(sign(secret, t, body), v1)


# ───────────────────────── URL safety (SSRF) ─────────────────────────
def _blocked_ip(ip: str) -> bool:
    a = ipaddress.ip_address(ip)
    return a.is_private or a.is_loopback or a.is_link_local or a.is_reserved or a.is_multicast or a.is_unspecified


def check_url(url: str, s: Settings) -> None:
    """Reject non-https and private/loopback/link-local targets (unless the dev-only escape hatch is set)."""
    u = urlsplit(url)
    if u.scheme not in ("https", "http") or not u.hostname or u.username or u.password:
        raise bad_request("invalid_webhook_url", "Webhook URL must be an http(s) URL without credentials")
    if s.webhook_allow_insecure_urls and not s.is_production:
        return
    if u.scheme != "https":
        raise bad_request("invalid_webhook_url", "Webhook URL must use https")
    try:
        infos = socket.getaddrinfo(u.hostname, u.port or 443, proto=socket.IPPROTO_TCP)
    except socket.gaierror as e:
        raise bad_request("invalid_webhook_url", "Webhook host does not resolve") from e
    if any(_blocked_ip(i[4][0]) for i in infos):
        raise bad_request("invalid_webhook_url", "Webhook URL must not point at a private or internal address")


# ───────────────────────── enqueue ─────────────────────────
def enqueue(c: Connection, business_id, event_type: str, event_id: str, data: dict) -> int:
    """Create one delivery per matching active endpoint. Returns how many were newly created."""
    payload = {"id": event_id, "type": event_type, "created": int(datetime.now(timezone.utc).timestamp()), "data": data}
    return sum(1 for e in repo.active_endpoints_for(c, business_id, event_type) if repo.enqueue(c, e["id"], event_id, event_type, payload))


def payment_data(c: Connection, inv: dict, p: dict, s: Settings) -> dict:
    d = inv["token_decimals"]
    sess = c.execute("select id, reference, metadata from checkout_sessions where invoice_id=%s", (inv["id"],)).fetchone()
    return {"payment_id": str(p["id"]), "invoice_id": str(inv["id"]), "invoice_number": inv["invoice_number"],
            "session_id": str(sess["id"]) if sess else None, "reference": sess["reference"] if sess else None,
            "metadata": sess["metadata"] if sess else {}, "amount": money(p["amount_base"], d), "amount_base": str(int(p["amount_base"])),
            "currency": inv["currency"], "payer_wallet": p["payer_wallet"], "tx_hash": p["tx_hash"],
            "explorer_url": explorer_tx(s, p["tx_hash"]), "chain_id": s.whitechain_chain_id, "token": s.whitechain_usdt_address}


# ───────────────────────── delivery ─────────────────────────
def deliver_due(s: Settings, limit: int = 20, client: httpx.Client | None = None) -> dict:
    """Send due deliveries. Safe to run from several workers (rows are claimed with SKIP LOCKED)."""
    with transaction() as c:
        due = repo.claim_due(c, limit)
    stats = {"sent": 0, "failed": 0, "gave_up": 0}
    own = client is None
    client = client or httpx.Client(timeout=s.webhook_timeout_seconds, follow_redirects=False)  # redirects could bypass the SSRF check
    try:
        for d in due:
            body = json.dumps(d["payload"], separators=(",", ":"), sort_keys=True)
            ts = int(time.time())
            err, code = None, None
            try:
                check_url(d["url"], s)
                r = client.post(d["url"], content=body, headers={
                    "Content-Type": "application/json", "User-Agent": "BillFlow-Webhooks/1",
                    "BillFlow-Signature": f"t={ts},v1={sign(d['secret'], ts, body)}", "BillFlow-Event-Id": d["event_id"]})
                code = r.status_code
                if 200 <= code < 300:
                    with transaction() as c:
                        repo.mark_delivered(c, d["id"], code)
                    stats["sent"] += 1
                    continue
                err = f"HTTP {code}"
            except Exception as e:  # noqa: BLE001 — network errors and URL-policy rejections are both retryable/loggable
                err = f"{type(e).__name__}: {e}"
            attempt = d["attempts"] + 1
            give_up = attempt >= s.webhook_max_attempts
            with transaction() as c:
                repo.mark_attempt_failed(c, d["id"], code, err, give_up, BACKOFF[min(attempt - 1, len(BACKOFF) - 1)])
            stats["gave_up" if give_up else "failed"] += 1
            log.warning("webhook %s attempt %s failed: %s", d["event_id"], attempt, err)
    finally:
        if own:
            client.close()
    return stats
