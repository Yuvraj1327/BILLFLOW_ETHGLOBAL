"""Row-level security still protects data if a client ever talks to Postgres/PostgREST directly with a user JWT.
The backend (trusted role) bypasses RLS on purpose; these tests prove RLS was NOT weakened to make queries work."""
import psycopg
import pytest

API = "/api/v1"


def as_user(uid, sql, params=()):
    with psycopg.connect(__import__("tests.conftest", fromlist=["x"]).TEST_DSN, autocommit=False, row_factory=psycopg.rows.dict_row) as c:
        c.execute("set local role authenticated")
        c.execute("select set_config('request.jwt.claim.sub', %s, true)", (str(uid),))
        try:
            cur = c.execute(sql, params)
            return cur.fetchall() if cur.description else cur.rowcount
        finally:
            c.rollback()


def test_rls_enabled_on_every_public_table(conn):
    rows = conn.execute("select c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace "
                        "where n.nspname='public' and c.relkind='r' and not c.relrowsecurity").fetchall()
    assert rows == [], f"tables without RLS: {rows}"


def test_user_sees_only_own_business_invoices(w, client):
    a, b = w.merchant(), w.merchant("0x" + "bb" * 20)
    ia = w.invoice(a, w.customer(a)); w.invoice(b, w.customer(b))
    assert [r["id"] for r in as_user(a["id"], "select id from invoices")] == [__import__("uuid").UUID(ia["id"])]
    assert as_user(w.user("customer")["id"], "select id from invoices") == []


def test_clients_cannot_write_money_tables(w, client):
    a = w.merchant(); inv = w.invoice(a, w.customer(a))
    for sql in ("update invoices set status='PAID', paid_amount_base=amount_base",
                "delete from invoices", "update financing_offers set status='FUNDED'",
                "insert into payments (invoice_id, payer_wallet, amount_base, tx_hash, log_index) values (gen_random_uuid(), '0x" + "11" * 20 + "', 1, '0x" + "22" * 32 + "', 0)"):
        try:
            n = as_user(a["id"], sql)
            assert n == 0, f"write succeeded: {sql}"  # RLS filtered every row
        except psycopg.errors.InsufficientPrivilege:
            pass
        except psycopg.errors.ForeignKeyViolation:
            pytest.fail(f"insert reached the table: {sql}")
    assert w.invoice_row(inv["id"])["status"] == "PENDING"


def test_backend_only_tables_are_closed_to_clients(w):
    u = w.user("merchant")
    for t in ("payment_quotes", "wallet_challenges"):
        try:
            assert as_user(u["id"], f"select * from {t}") == []
        except psycopg.errors.InsufficientPrivilege:
            pass
