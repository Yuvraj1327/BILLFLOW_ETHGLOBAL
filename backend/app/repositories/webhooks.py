"""Webhook endpoints, deliveries and API keys (all backend-only tables)."""
from __future__ import annotations

from psycopg import Connection
from psycopg.types.json import Jsonb

# ── endpoints ──
def create_endpoint(c: Connection, business_id, url: str, secret: str, events: list[str]) -> dict:
    return c.execute("insert into webhook_endpoints (business_id, url, secret, events) values (%s,%s,%s,%s) returning *",
                     (business_id, url, secret, events)).fetchone()


def list_endpoints(c: Connection, business_id) -> list[dict]:
    return c.execute("select * from webhook_endpoints where business_id=%s order by created_at", (business_id,)).fetchall()


def get_endpoint(c: Connection, business_id, endpoint_id) -> dict | None:
    return c.execute("select * from webhook_endpoints where id=%s and business_id=%s", (endpoint_id, business_id)).fetchone()


def set_active(c: Connection, business_id, endpoint_id, active: bool) -> bool:
    return c.execute("update webhook_endpoints set active=%s where id=%s and business_id=%s returning id",
                     (active, endpoint_id, business_id)).fetchone() is not None


def delete_endpoint(c: Connection, business_id, endpoint_id) -> bool:
    return c.execute("delete from webhook_endpoints where id=%s and business_id=%s returning id", (endpoint_id, business_id)).fetchone() is not None


def active_endpoints_for(c: Connection, business_id, event_type: str) -> list[dict]:
    return c.execute("""select * from webhook_endpoints where business_id=%s and active and ('*'=any(events) or %s=any(events))""",
                     (business_id, event_type)).fetchall()


# ── deliveries ──
def enqueue(c: Connection, endpoint_id, event_id: str, event_type: str, payload: dict) -> bool:
    return c.execute("""insert into webhook_deliveries (endpoint_id, event_id, event_type, payload) values (%s,%s,%s,%s)
                        on conflict (endpoint_id, event_id) do nothing returning id""",
                     (endpoint_id, event_id, event_type, Jsonb(payload))).fetchone() is not None


def claim_due(c: Connection, limit: int) -> list[dict]:
    """Lock due deliveries (skip ones another worker holds) and push next_attempt_at forward so they are not re-claimed
    while this worker is still sending."""
    return c.execute("""update webhook_deliveries d set next_attempt_at = now() + interval '2 minutes'
                        where d.id in (select id from webhook_deliveries where status='PENDING' and next_attempt_at <= now()
                                       order by next_attempt_at, created_at limit %s for update skip locked)
                        returning d.*, (select url from webhook_endpoints e where e.id=d.endpoint_id) as url,
                                       (select secret from webhook_endpoints e where e.id=d.endpoint_id) as secret""", (limit,)).fetchall()


def mark_delivered(c: Connection, delivery_id, status_code: int) -> None:
    c.execute("update webhook_deliveries set status='DELIVERED', attempts=attempts+1, last_status=%s, last_error=null, delivered_at=now() where id=%s",
              (status_code, delivery_id))


def mark_attempt_failed(c: Connection, delivery_id, status_code: int | None, error: str, give_up: bool, delay_seconds: int) -> None:
    c.execute("""update webhook_deliveries set attempts=attempts+1, last_status=%s, last_error=%s,
                 status=case when %s then 'FAILED' else 'PENDING' end, next_attempt_at=now() + make_interval(secs => %s) where id=%s""",
              (status_code, error[:300], give_up, delay_seconds, delivery_id))


def list_deliveries(c: Connection, business_id, limit: int = 50) -> list[dict]:
    return c.execute("""select d.id, d.endpoint_id, d.event_id, d.event_type, d.status, d.attempts, d.last_status, d.last_error,
                        d.delivered_at, d.created_at from webhook_deliveries d join webhook_endpoints e on e.id=d.endpoint_id
                        where e.business_id=%s order by d.created_at desc limit %s""", (business_id, limit)).fetchall()


def retry_failed(c: Connection, business_id, delivery_id) -> bool:
    return c.execute("""update webhook_deliveries d set status='PENDING', next_attempt_at=now() from webhook_endpoints e
                        where d.id=%s and e.id=d.endpoint_id and e.business_id=%s and d.status='FAILED' returning d.id""",
                     (delivery_id, business_id)).fetchone() is not None


# ── API keys ──
def create_key(c: Connection, business_id, name: str, prefix: str, key_hash: str, created_by) -> dict:
    return c.execute("insert into api_keys (business_id, name, key_prefix, key_hash, created_by) values (%s,%s,%s,%s,%s) returning *",
                     (business_id, name, prefix, key_hash, created_by)).fetchone()


def list_keys(c: Connection, business_id) -> list[dict]:
    return c.execute("select id, name, key_prefix, last_used_at, revoked_at, created_at from api_keys where business_id=%s order by created_at desc",
                     (business_id,)).fetchall()


def revoke_key(c: Connection, business_id, key_id) -> bool:
    return c.execute("update api_keys set revoked_at=now() where id=%s and business_id=%s and revoked_at is null returning id",
                     (key_id, business_id)).fetchone() is not None


def key_by_hash(c: Connection, key_hash: str) -> dict | None:
    return c.execute("select * from api_keys where key_hash=%s", (key_hash,)).fetchone()


def touch_key(c: Connection, key_id) -> None:
    c.execute("update api_keys set last_used_at=now() where id=%s", (key_id,))
