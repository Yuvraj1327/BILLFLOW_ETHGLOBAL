from __future__ import annotations

from uuid import UUID

from psycopg import Connection


def get(c: Connection, user_id: UUID | str) -> dict | None:
    return c.execute("select * from profiles where id=%s", (user_id,)).fetchone()


def get_by_wallet(c: Connection, wallet: str) -> dict | None:
    return c.execute("select * from profiles where wallet_address=%s", (wallet.lower(),)).fetchone()


def get_by_email(c: Connection, email: str) -> dict | None:
    return c.execute("select * from profiles where lower(email)=lower(%s)", (email,)).fetchone()


def update_basic(c: Connection, user_id, display_name: str | None) -> dict:
    return c.execute("update profiles set display_name=coalesce(%s, display_name) where id=%s returning *",
                     (display_name, user_id)).fetchone()


def set_wallet(c: Connection, user_id, wallet: str) -> dict:
    return c.execute("update profiles set wallet_address=%s where id=%s returning *", (wallet.lower(), user_id)).fetchone()


def set_role(c: Connection, user_id, role: str) -> dict | None:
    return c.execute("update profiles set role=%s::user_role where id=%s returning *", (role, user_id)).fetchone()


def set_investor_verification(c: Connection, user_id, status: str) -> dict | None:
    return c.execute("update profiles set investor_verification=%s::verification_status where id=%s returning *",
                     (status, user_id)).fetchone()


def list_users(c: Connection, role: str | None, q: str | None, limit: int, offset: int) -> tuple[list[dict], int]:
    where, p = ["true"], []
    if role:
        where.append("role=%s::user_role"); p.append(role)
    if q:
        where.append("(email ilike %s or display_name ilike %s)"); p += [f"%{q}%", f"%{q}%"]
    w = " and ".join(where)
    total = c.execute(f"select count(*) n from profiles where {w}", p).fetchone()["n"]
    rows = c.execute(f"select * from profiles where {w} order by created_at desc limit %s offset %s", p + [limit, offset]).fetchall()
    return rows, total


def create_challenge(c: Connection, user_id, wallet: str, nonce: str, ttl_minutes: int = 10) -> dict:
    return c.execute("""insert into wallet_challenges (user_id, wallet_address, nonce, expires_at)
                        values (%s,%s,%s, now() + make_interval(mins => %s)) returning *""",
                     (user_id, wallet.lower(), nonce, ttl_minutes)).fetchone()


def consume_challenge(c: Connection, user_id, wallet: str, nonce: str) -> bool:
    r = c.execute("""update wallet_challenges set used_at=now() where user_id=%s and wallet_address=%s and nonce=%s
                     and used_at is null and expires_at > now() returning id""", (user_id, wallet.lower(), nonce)).fetchone()
    return r is not None
