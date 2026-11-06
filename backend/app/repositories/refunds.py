"""Refund records (mirror of on-chain BillFlowRefunds events)."""
from __future__ import annotations

from psycopg import Connection

from app.core.dependencies import PageParams

_J = """select r.*, p.onchain_payment_id, p.payer_wallet, p.tx_hash as payment_tx_hash, i.invoice_number, i.token_decimals
        from refunds r join payments p on p.id=r.payment_id join invoices i on i.id=r.invoice_id"""


def insert_pending(c: Connection, d: dict) -> dict:
    return c.execute("""insert into refunds (payment_id, invoice_id, business_id, amount_base, refund_ref, reason, reason_hash, requested_by)
                        values (%(payment_id)s,%(invoice_id)s,%(business_id)s,%(amount_base)s,%(refund_ref)s,%(reason)s,%(reason_hash)s,%(requested_by)s)
                        returning id""", d).fetchone()


def insert_confirmed(c: Connection, d: dict) -> dict | None:
    return c.execute("""insert into refunds (payment_id, invoice_id, business_id, amount_base, refund_ref, reason_hash, status,
                          onchain_refund_id, tx_hash, log_index, block_number, refunded_at)
                        values (%(payment_id)s,%(invoice_id)s,%(business_id)s,%(amount_base)s,%(refund_ref)s,%(reason_hash)s,'CONFIRMED',
                          %(onchain_refund_id)s,%(tx_hash)s,%(log_index)s,%(block_number)s, now())
                        on conflict do nothing returning id""", d).fetchone()


def get(c: Connection, refund_id, lock: bool = False) -> dict | None:
    return c.execute(_J + " where r.id=%s" + (" for update of r" if lock else ""), (refund_id,)).fetchone()


def by_ref(c: Connection, ref: str, lock: bool = False) -> dict | None:
    return c.execute(_J + " where r.refund_ref=%s" + (" for update of r" if lock else ""), (ref,)).fetchone()


def by_tx_log(c: Connection, tx_hash: str, log_index: int) -> dict | None:
    return c.execute(_J + " where r.tx_hash=%s and r.log_index=%s", (tx_hash, log_index)).fetchone()


def for_payment(c: Connection, payment_id) -> list[dict]:
    return c.execute(_J + " where r.payment_id=%s order by r.created_at", (payment_id,)).fetchall()


def pending_amount(c: Connection, payment_id) -> int:
    return int(c.execute("select coalesce(sum(amount_base),0) n from refunds where payment_id=%s and status='PENDING'",
                         (payment_id,)).fetchone()["n"])


def confirm(c: Connection, refund_id, d: dict) -> None:
    c.execute("""update refunds set status='CONFIRMED', onchain_refund_id=%(onchain_refund_id)s, tx_hash=%(tx_hash)s,
                 log_index=%(log_index)s, block_number=%(block_number)s, refunded_at=now() where id=%(id)s""", {**d, "id": refund_id})


def list_(c: Connection, business_id, status: str | None, pg: PageParams) -> tuple[list[dict], int]:
    w, p = ["r.business_id=%s"], [business_id]
    if status:
        w.append("r.status=%s::refund_status"); p.append(status)
    ws = " and ".join(w)
    total = c.execute(f"select count(*) n from refunds r where {ws}", p).fetchone()["n"]
    return c.execute(f"{_J} where {ws} order by r.created_at desc limit %s offset %s", p + [pg.page_size, pg.offset]).fetchall(), total
