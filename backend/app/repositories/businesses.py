"""Businesses, members and customers."""
from __future__ import annotations

from psycopg import Connection

from app.core.dependencies import PageParams


def create_business(c: Connection, owner_id, d: dict) -> dict:
    b = c.execute("""insert into businesses (owner_id, legal_name, country, tax_id, payout_wallet)
                     values (%s,%s,%s,%s,%s) returning *""",
                  (owner_id, d["legal_name"], d.get("country"), d.get("tax_id"), d.get("payout_wallet"))).fetchone()
    c.execute("insert into business_members (business_id, user_id, member_role) values (%s,%s,'owner') on conflict do nothing",
              (b["id"], owner_id))
    return b


def ensure_business(c: Connection, user_id, display_name: str | None, email: str | None) -> dict | None:
    """Idempotent starter business for a merchant (editable via PATCH /businesses/me). Serialised per user, so the several
    requests a dashboard fires at once cannot create duplicates."""
    b = business_of_user(c, user_id)
    if b:
        return b
    c.execute("select pg_advisory_xact_lock(hashtextextended(%s, 0))", (f"biz:{user_id}",))
    b = business_of_user(c, user_id)  # re-check: a concurrent request may have created it while we waited
    if b:
        return b
    name = (display_name or "").strip() or (email or "").split("@")[0] or "My business"
    return create_business(c, user_id, {"legal_name": name if len(name) >= 2 else "My business"})


def get_business(c: Connection, business_id) -> dict | None:
    return c.execute("select * from businesses where id=%s", (business_id,)).fetchone()


def business_of_user(c: Connection, user_id) -> dict | None:
    return c.execute("""select b.* from businesses b where b.owner_id=%s
                        union all select b.* from businesses b join business_members m on m.business_id=b.id where m.user_id=%s
                        limit 1""", (user_id, user_id)).fetchone()


def update_business(c: Connection, business_id, d: dict) -> dict:
    sets = [f"{k}=%s" for k in d]
    return c.execute(f"update businesses set {', '.join(sets)} where id=%s returning *", [*d.values(), business_id]).fetchone()


def set_business_verification(c: Connection, business_id, status: str, admin_id) -> dict | None:
    return c.execute("""update businesses set verification_status=%s::verification_status, verified_by=%s,
                        verified_at=case when %s='verified' then now() end where id=%s returning *""",
                     (status, admin_id, status, business_id)).fetchone()


def list_businesses(c: Connection, status: str | None, pg: PageParams) -> tuple[list[dict], int]:
    w, p = "true", []
    if status:
        w, p = "verification_status=%s::verification_status", [status]
    total = c.execute(f"select count(*) n from businesses where {w}", p).fetchone()["n"]
    return c.execute(f"select * from businesses where {w} order by created_at desc limit %s offset %s",
                     p + [pg.page_size, pg.offset]).fetchall(), total


def list_members(c: Connection, business_id) -> list[dict]:
    return c.execute("""select m.business_id, m.user_id, m.member_role, m.created_at, p.email, p.display_name
                        from business_members m join profiles p on p.id=m.user_id where m.business_id=%s order by m.created_at""",
                     (business_id,)).fetchall()


def add_member(c: Connection, business_id, user_id) -> dict:
    return c.execute("""insert into business_members (business_id, user_id, member_role) values (%s,%s,'member')
                        on conflict (business_id, user_id) do update set business_id=excluded.business_id returning *""",
                     (business_id, user_id)).fetchone()


def remove_member(c: Connection, business_id, user_id) -> bool:
    return c.execute("delete from business_members where business_id=%s and user_id=%s and member_role<>'owner' returning 1",
                     (business_id, user_id)).fetchone() is not None


# customers
def create_customer(c: Connection, business_id, d: dict) -> dict:
    return c.execute("insert into customers (business_id, name, email, wallet_address) values (%s,%s,%s,%s) returning *",
                     (business_id, d["name"], d.get("email"), d.get("wallet_address"))).fetchone()


def get_customer(c: Connection, business_id, customer_id) -> dict | None:
    return c.execute("select * from customers where id=%s and business_id=%s", (customer_id, business_id)).fetchone()


def list_customers(c: Connection, business_id, q: str | None, include_archived: bool, pg: PageParams) -> tuple[list[dict], int]:
    w, p = ["business_id=%s"], [business_id]
    if not include_archived:
        w.append("archived_at is null")
    if q:
        w.append("(name ilike %s or email ilike %s)"); p += [f"%{q}%", f"%{q}%"]
    ws = " and ".join(w)
    total = c.execute(f"select count(*) n from customers where {ws}", p).fetchone()["n"]
    return c.execute(f"select * from customers where {ws} order by name limit %s offset %s", p + [pg.page_size, pg.offset]).fetchall(), total


def update_customer(c: Connection, business_id, customer_id, d: dict) -> dict | None:
    if not d:
        return get_customer(c, business_id, customer_id)
    sets = [f"{k}=%s" for k in d]
    return c.execute(f"update customers set {', '.join(sets)} where id=%s and business_id=%s returning *",
                     [*d.values(), customer_id, business_id]).fetchone()


def archive_customer(c: Connection, business_id, customer_id) -> bool:
    return c.execute("update customers set archived_at=coalesce(archived_at, now()) where id=%s and business_id=%s returning 1",
                     (customer_id, business_id)).fetchone() is not None
