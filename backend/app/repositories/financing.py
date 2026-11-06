"""Financing offers and investments."""
from __future__ import annotations

from psycopg import Connection
from psycopg.types.json import Jsonb

from app.core.dependencies import PageParams

_OFFER = """select f.*, i.invoice_number, i.invoice_hash, i.onchain_invoice_id, i.token_decimals, i.due_date as invoice_due_date,
  b.legal_name as business_name, b.verification_status as business_verification, b.payout_wallet
  from financing_offers f join invoices i on i.id=f.invoice_id join businesses b on b.id=f.business_id"""


def insert_offer(c: Connection, d: dict) -> dict:
    cols = ", ".join(d)
    return c.execute(f"insert into financing_offers ({cols}) values ({', '.join(['%s'] * len(d))}) returning id", list(d.values())).fetchone()


def get_offer(c: Connection, offer_id, lock: bool = False) -> dict | None:
    return c.execute(_OFFER + " where f.id=%s" + (" for update of f" if lock else ""), (offer_id,)).fetchone()


def get_offer_by_invoice(c: Connection, invoice_id) -> dict | None:
    return c.execute(_OFFER + " where f.invoice_id=%s", (invoice_id,)).fetchone()


def get_offer_by_hash(c: Connection, invoice_hash: str, lock: bool = False) -> dict | None:
    return c.execute(_OFFER + " where i.invoice_hash=%s" + (" for update of f" if lock else ""), (invoice_hash,)).fetchone()


def get_offer_by_onchain_id(c: Connection, onchain_id: str, lock: bool = False) -> dict | None:
    return c.execute(_OFFER + " where f.onchain_offer_id=%s" + (" for update of f" if lock else ""), (onchain_id,)).fetchone()


def list_offers(c: Connection, *, business_id=None, statuses: list[str] | None = None, pg: PageParams) -> tuple[list[dict], int]:
    w, p = ["true"], []
    if business_id:
        w.append("f.business_id=%s"); p.append(business_id)
    if statuses:
        w.append("f.status = any(%s::financing_status[])"); p.append(statuses)
    ws = " and ".join(w)
    total = c.execute(f"select count(*) n from financing_offers f where {ws}", p).fetchone()["n"]
    return c.execute(f"{_OFFER} where {ws} order by f.created_at desc limit %s offset %s", p + [pg.page_size, pg.offset]).fetchall(), total


def update_offer(c: Connection, offer_id, d: dict) -> None:
    sets, vals = [], []
    for k, v in d.items():
        if k == "status":
            sets.append("status=%s::financing_status")
        elif isinstance(v, (dict, list)):
            sets.append(f"{k}=%s"); v = Jsonb(v); vals.append(v); continue
        else:
            sets.append(f"{k}=%s")
        vals.append(v)
    c.execute(f"update financing_offers set {', '.join(sets)} where id=%s", [*vals, offer_id])


# investments
_INV = """select v.*, f.invoice_id, f.face_value_base, f.advance_base, f.maturity_date, f.status as offer_status,
  f.business_id, i.invoice_number, i.token_decimals from investments v
  join financing_offers f on f.id=v.offer_id join invoices i on i.id=f.invoice_id"""


def insert_investment(c: Connection, offer_id, investor_id, wallet, amount, tx_hash) -> dict | None:
    return c.execute("""insert into investments (offer_id, investor_id, investor_wallet, amount_base, tx_hash, status, funded_at)
                        values (%s,%s,%s,%s,%s,'CONFIRMED', now()) on conflict do nothing returning *""",
                     (offer_id, investor_id, wallet, amount, tx_hash)).fetchone()


def investment_for_offer(c: Connection, offer_id) -> dict | None:
    return c.execute("select * from investments where offer_id=%s and status in ('PENDING','CONFIRMED','SETTLED')", (offer_id,)).fetchone()


def update_investment(c: Connection, inv_id, d: dict) -> None:
    sets, vals = [], []
    for k, v in d.items():
        sets.append("status=%s::investment_status" if k == "status" else f"{k}=%s")
        vals.append(v)
    c.execute(f"update investments set {', '.join(sets)} where id=%s", [*vals, inv_id])


def get_investment(c: Connection, inv_id) -> dict | None:
    return c.execute(_INV + " where v.id=%s", (inv_id,)).fetchone()


def list_investments(c: Connection, *, investor_id=None, business_id=None, settled_only=False, pg: PageParams) -> tuple[list[dict], int]:
    w, p = ["true"], []
    if investor_id:
        w.append("v.investor_id=%s"); p.append(investor_id)
    if business_id:
        w.append("f.business_id=%s"); p.append(business_id)
    if settled_only:
        w.append("v.status='SETTLED'")
    ws = " and ".join(w)
    total = c.execute(f"select count(*) n from investments v join financing_offers f on f.id=v.offer_id where {ws}", p).fetchone()["n"]
    return c.execute(f"{_INV} where {ws} order by v.created_at desc limit %s offset %s", p + [pg.page_size, pg.offset]).fetchall(), total


INACTIVE = ("REJECTED", "CANCELLED", "EXPIRED")


def duplicate_financing_conflicts(c, inv: dict) -> list[dict]:
    """Other invoices that are ALREADY in an active financing offer and look like this one: same supporting PDF (SHA-256), or the same
    invoice identity (number + amount + due date + debtor) at another business, or a same-business look-alike (customer + amount + issue
    date). Used to hard-block double financing; admins still review everything else."""
    return c.execute("""
        select f.id as offer_id, f.invoice_id, 'same_document' as reason
          from financing_offers f join invoice_documents d on d.invoice_id=f.invoice_id
         where d.sha256 in (select sha256 from invoice_documents where invoice_id=%(id)s)
           and f.invoice_id<>%(id)s and f.status not in ('REJECTED','CANCELLED','EXPIRED')
        union
        select f.id, f.invoice_id, 'same_invoice_data'
          from financing_offers f join invoices i on i.id=f.invoice_id
         where f.invoice_id<>%(id)s and f.status not in ('REJECTED','CANCELLED','EXPIRED')
           and ((i.business_id<>%(biz)s and i.invoice_number=%(num)s and i.amount_base=%(amt)s and i.due_date=%(due)s
                 and lower(f.debtor_name)=lower(%(debtor)s))
             or (i.business_id=%(biz)s and i.customer_id=%(cust)s and i.amount_base=%(amt)s and i.issue_date=%(issue)s))
        """, {"id": inv["id"], "biz": inv["business_id"], "num": inv["invoice_number"], "amt": inv["amount_base"], "due": inv["due_date"],
              "debtor": inv.get("customer_name") or "", "cust": inv["customer_id"], "issue": inv["issue_date"]}).fetchall()
