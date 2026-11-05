"""Invoices, documents, payment links, payment quotes."""
from __future__ import annotations

from psycopg import Connection
from psycopg.types.json import Jsonb

from app.core.dependencies import PageParams, sort_clause

SORTS = {"created_at": "i.created_at", "due_date": "i.due_date", "amount": "i.amount_base", "status": "i.status",
         "invoice_number": "i.invoice_number"}

_SELECT = """select i.*, c.name as customer_name,
  (select d.sha256 from invoice_documents d where d.invoice_id=i.id order by d.created_at desc limit 1) as document_sha256,
  (select f.status from financing_offers f where f.invoice_id=i.id) as financing_status,
  (select f.id from financing_offers f where f.invoice_id=i.id) as financing_offer_id
  from invoices i join customers c on c.id=i.customer_id"""


def insert(c: Connection, d: dict) -> dict:
    cols = ", ".join(d)
    return c.execute(f"insert into invoices ({cols}) values ({', '.join(['%s'] * len(d))}) returning id", list(d.values())).fetchone()


def get(c: Connection, invoice_id, business_id=None, lock: bool = False) -> dict | None:
    sql = _SELECT + " where i.id=%s" + (" and i.business_id=%s" if business_id else "")
    if lock:
        sql += " for update of i"
    return c.execute(sql, (invoice_id, business_id) if business_id else (invoice_id,)).fetchone()


def get_by_onchain_id(c: Connection, onchain_id: str, lock: bool = False) -> dict | None:
    return c.execute("select i.*, b.payout_wallet, b.legal_name from invoices i join businesses b on b.id=i.business_id "
                     "where i.onchain_invoice_id=%s" + (" for update of i" if lock else ""), (onchain_id,)).fetchone()


def list_(c: Connection, business_id, status, customer_id, q, sort, order, pg: PageParams) -> tuple[list[dict], int]:
    w, p = ["i.business_id=%s"], [business_id]
    if status:
        w.append("i.status=%s::invoice_status"); p.append(status)
    if customer_id:
        w.append("i.customer_id=%s"); p.append(customer_id)
    if q:
        w.append("(i.invoice_number ilike %s or i.description ilike %s or c.name ilike %s)"); p += [f"%{q}%"] * 3
    ws = " and ".join(w)
    total = c.execute(f"select count(*) n from invoices i join customers c on c.id=i.customer_id where {ws}", p).fetchone()["n"]
    rows = c.execute(f"{_SELECT} where {ws} order by {sort_clause(sort, order, SORTS, 'created_at')} limit %s offset %s",
                     p + [pg.page_size, pg.offset]).fetchall()
    return rows, total


def update(c: Connection, invoice_id, d: dict) -> None:
    sets = [f"{k}=%s" for k in d]
    c.execute(f"update invoices set {', '.join(sets)} where id=%s", [*d.values(), invoice_id])


def delete(c: Connection, invoice_id) -> None:
    c.execute("delete from invoices where id=%s", (invoice_id,))


# documents
def add_document(c: Connection, d: dict) -> dict:
    return c.execute("""insert into invoice_documents (invoice_id, business_id, storage_path, sha256, mime_type, size_bytes, uploaded_by)
                        values (%(invoice_id)s,%(business_id)s,%(storage_path)s,%(sha256)s,%(mime_type)s,%(size_bytes)s,%(uploaded_by)s)
                        returning *""", d).fetchone()


def get_document(c: Connection, business_id, doc_id) -> dict | None:
    return c.execute("select * from invoice_documents where id=%s and business_id=%s", (doc_id, business_id)).fetchone()


def list_documents(c: Connection, invoice_id) -> list[dict]:
    return c.execute("select * from invoice_documents where invoice_id=%s order by created_at desc", (invoice_id,)).fetchall()


def other_documents_with_hash(c: Connection, sha256: str, exclude_invoice) -> list[dict]:
    return c.execute("""select d.invoice_id, d.business_id, i.invoice_number from invoice_documents d
                        left join invoices i on i.id=d.invoice_id
                        where d.sha256=%s and (d.invoice_id is distinct from %s)""", (sha256, exclude_invoice)).fetchall()


def save_ai(c: Connection, doc_id, extraction: dict | None, confidence: float | None, flags: list) -> None:
    c.execute("update invoice_documents set ai_extraction=%s, ai_confidence=%s, ai_flags=%s where id=%s",
              (Jsonb(extraction) if extraction is not None else None, confidence, Jsonb(flags), doc_id))


def duplicates(c: Connection, business_id, invoice_id, invoice_number: str | None, customer_id, amount_base, issue_date) -> list[dict]:
    return c.execute("""select id, invoice_number, status from invoices where business_id=%s and id is distinct from %s and (
                        invoice_number=%s or (customer_id=%s and amount_base=%s and issue_date=%s))""",
                     (business_id, invoice_id, invoice_number, customer_id, amount_base, issue_date)).fetchall()


# payment links
def revoke_links(c: Connection, invoice_id) -> None:
    c.execute("update payment_links set revoked_at=now() where invoice_id=%s and revoked_at is null", (invoice_id,))


def create_link(c: Connection, invoice_id, token: str, ttl_days: int) -> dict:
    return c.execute("insert into payment_links (invoice_id, token, expires_at) values (%s,%s, now() + make_interval(days => %s)) returning *",
                     (invoice_id, token, ttl_days)).fetchone()


def active_link(c: Connection, invoice_id) -> dict | None:
    return c.execute("""select * from payment_links where invoice_id=%s and revoked_at is null
                        and (expires_at is null or expires_at > now()) order by created_at desc limit 1""", (invoice_id,)).fetchone()


def link_by_token(c: Connection, token: str) -> dict | None:
    return c.execute("select * from payment_links where token=%s", (token,)).fetchone()


# quotes
def add_quote(c: Connection, invoice_id, payer: str, amount: int, nonce: int, ttl_seconds: int) -> dict:
    return c.execute("""insert into payment_quotes (invoice_id, payer_wallet, amount_base, nonce, expiry)
                        values (%s,%s,%s,%s, now() + make_interval(secs => %s)) returning *""",
                     (invoice_id, payer, amount, nonce, ttl_seconds)).fetchone()


def overdue_candidates(c: Connection) -> list[dict]:
    return c.execute("""update invoices set status='OVERDUE' where status in ('PENDING','PARTIALLY_PAID') and due_date < current_date
                        returning id, business_id, invoice_number""").fetchall()
