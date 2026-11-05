from __future__ import annotations

from psycopg import Connection

from app.core.dependencies import PageParams

_J = """select p.*, i.invoice_number, i.business_id, i.token_decimals from payments p join invoices i on i.id=p.invoice_id"""


def insert_if_new(c: Connection, invoice_id, payer, amount, tx_hash, log_index, block_number) -> dict | None:
    """None means (tx_hash, log_index) was already recorded -> duplicate, nothing to do."""
    return c.execute("""insert into payments (invoice_id, payer_wallet, amount_base, tx_hash, log_index, block_number, status, confirmed_at)
                        values (%s,%s,%s,%s,%s,%s,'CONFIRMED', now()) on conflict (tx_hash, log_index) do nothing returning *""",
                     (invoice_id, payer, amount, tx_hash, log_index, block_number)).fetchone()


def get(c: Connection, payment_id) -> dict | None:
    return c.execute(_J + " where p.id=%s", (payment_id,)).fetchone()


def by_tx(c: Connection, tx_hash: str) -> list[dict]:
    return c.execute(_J + " where p.tx_hash=%s order by p.log_index", (tx_hash,)).fetchall()


def for_invoice(c: Connection, invoice_id) -> list[dict]:
    return c.execute(_J + " where p.invoice_id=%s order by p.created_at", (invoice_id,)).fetchall()


def list_(c: Connection, *, business_id=None, payer_wallet=None, invoice_id=None, pg: PageParams) -> tuple[list[dict], int]:
    w, p = ["true"], []
    if business_id:
        w.append("i.business_id=%s"); p.append(business_id)
    if payer_wallet:
        w.append("p.payer_wallet=%s"); p.append(payer_wallet)
    if invoice_id:
        w.append("p.invoice_id=%s"); p.append(invoice_id)
    ws = " and ".join(w)
    total = c.execute(f"select count(*) n from payments p join invoices i on i.id=p.invoice_id where {ws}", p).fetchone()["n"]
    return c.execute(f"{_J} where {ws} order by p.created_at desc limit %s offset %s", p + [pg.page_size, pg.offset]).fetchall(), total
