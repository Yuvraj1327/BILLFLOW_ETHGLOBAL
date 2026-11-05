from __future__ import annotations

import os
import subprocess
import uuid
from datetime import date, timedelta
from pathlib import Path

import psycopg
import pytest

ROOT = Path(__file__).resolve().parents[2]
MIGRATIONS = sorted((ROOT / "supabase" / "migrations").glob("*.sql"))
ADMIN_DSN = os.environ.get("TEST_PG_ADMIN_DSN", "postgresql://postgres@/postgres?host=/tmp&port=54329")
DB_NAME = "billflow_test"
TEST_DSN = ADMIN_DSN.replace("/postgres?", f"/{DB_NAME}?")

# Settings for the whole test run: set BEFORE app modules read them.
os.environ.update({
    "DATABASE_URL": TEST_DSN, "SUPABASE_JWT_SECRET": "test-jwt-secret-test-jwt-secret-1234567890",
    "SUPABASE_URL": "https://example.supabase.test", "SUPABASE_ANON_KEY": "anon-test", "SUPABASE_SERVICE_ROLE_KEY": "service-test",
    "WHITECHAIN_CHAIN_ID": "1874", "WHITECHAIN_USDT_ADDRESS": "0x" + "11" * 20, "USDT_DECIMALS": "6",
    "WHITECHAIN_PAYMENT_CONTRACT": "0x" + "22" * 20, "WHITECHAIN_FINANCING_CONTRACT": "0x" + "33" * 20,
    "QUOTE_SIGNER_PRIVATE_KEY": "0x" + "ab" * 32, "MIN_CONFIRMATIONS": "3", "ANTHROPIC_API_KEY": "test", "ANTHROPIC_MODEL": "test-model",
    "PUBLIC_CHECKOUT_BASE_URL": "https://pay.test", "APP_ENV": "test", "INDEXER_ENABLED": "false",
})
for k in ("WHITECHAIN_INVOICE_REGISTRY", "SUPABASE_JWT_JWKS_URL"):
    os.environ.pop(k, None)

STUB = """
do $$ begin
  if not exists (select from pg_roles where rolname='anon') then create role anon nologin; end if;
  if not exists (select from pg_roles where rolname='authenticated') then create role authenticated nologin; end if;
  if not exists (select from pg_roles where rolname='service_role') then create role service_role nologin bypassrls; end if;
end $$;
create schema auth;
create table auth.users (id uuid primary key default gen_random_uuid(), email text, raw_user_meta_data jsonb not null default '{}');
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
create schema storage;
create table storage.buckets (id text primary key, name text, public boolean, file_size_limit bigint, allowed_mime_types text[]);
"""


@pytest.fixture(scope="session")
def _db():
    try:
        with psycopg.connect(ADMIN_DSN, autocommit=True, connect_timeout=3) as c:
            c.execute(f"drop database if exists {DB_NAME} with (force)")
            c.execute(f"create database {DB_NAME} encoding 'UTF8' template template0 lc_collate 'C' lc_ctype 'C'")
    except psycopg.OperationalError as e:  # pragma: no cover
        pytest.skip(f"local Postgres not reachable ({e}); set TEST_PG_ADMIN_DSN", allow_module_level=False)
    with psycopg.connect(TEST_DSN, autocommit=True) as c:
        c.execute(STUB)
        for m in MIGRATIONS:
            c.execute(m.read_text())
    from app.core.database import close_pool, init_pool
    init_pool(TEST_DSN, 1, 6)
    yield
    close_pool()


@pytest.fixture()
def db(_db):
    """Clean tables before each test (migrations stay)."""
    with psycopg.connect(TEST_DSN, autocommit=True) as c:
        names = [r[0] for r in c.execute("select tablename from pg_tables where schemaname='public'").fetchall()]
        c.execute("truncate " + ", ".join(f'public."{n}"' for n in names) + ", auth.users restart identity cascade")
        c.execute("insert into platform_settings (key, value) values ('max_discount_bps','2000'::jsonb) on conflict do nothing")
    from app.core.dependencies import reset_rate_limits
    reset_rate_limits()
    yield TEST_DSN


@pytest.fixture()
def conn(db):
    with psycopg.connect(TEST_DSN, autocommit=True, row_factory=psycopg.rows.dict_row) as c:
        yield c


@pytest.fixture()
def chain(db):
    from app.services.blockchain_service import set_chain_client
    from tests.helpers import FakeChain
    fc = FakeChain()
    set_chain_client(fc)
    yield fc
    set_chain_client(None)


@pytest.fixture()
def storage(db):
    from app.services.supabase_client import set_storage
    from tests.helpers import FakeStorage
    st = FakeStorage()
    set_storage(st)
    yield st
    set_storage(None)


@pytest.fixture()
def llm(db):
    from app.services.anthropic_service import set_llm
    from tests.helpers import FakeLLM
    f = FakeLLM()
    set_llm(f)
    yield f
    set_llm(None)


@pytest.fixture()
def authc(db):
    from app.services.supabase_client import set_supabase
    from tests.helpers import FakeAuth
    f = FakeAuth()
    set_supabase(f)
    yield f
    set_supabase(None)


@pytest.fixture()
def client(db, chain, storage, llm, authc):
    from fastapi.testclient import TestClient
    from app.main import create_app
    with TestClient(create_app()) as tc:
        yield tc


# ───────────── data builders ─────────────
class World:
    """Creates users/businesses/invoices directly in the DB; requests go through the real API."""

    def __init__(self, conn, client):
        self.c, self.client = conn, client

    def user(self, role: str, email: str | None = None) -> dict:
        uid = uuid.uuid4()
        email = email or f"{role}-{uid.hex[:6]}@test.io"
        self.c.execute("insert into auth.users (id, email, raw_user_meta_data) values (%s,%s,%s)",
                       (uid, email, psycopg.types.json.Jsonb({"role": role if role in ("merchant", "investor") else "customer"})))
        if role == "admin":
            self.c.execute("update profiles set role='admin' where id=%s", (uid,))
        from tests.helpers import token
        return {"id": uid, "email": email, "h": {"Authorization": f"Bearer {token(uid)}"}}

    def set_wallet(self, u: dict, wallet: str):
        self.c.execute("update profiles set wallet_address=%s where id=%s", (wallet.lower(), u["id"]))

    def merchant(self, wallet: str = "0x" + "aa" * 20, verified: bool = True) -> dict:
        u = self.user("merchant")
        r = self.client.post("/api/v1/businesses", json={"legal_name": "Acme Ltd", "payout_wallet": wallet}, headers=u["h"])
        assert r.status_code == 201, r.text
        u["business"] = r.json()
        if verified:
            self.c.execute("update businesses set verification_status='verified' where id=%s", (u["business"]["id"],))
        return u

    def customer(self, m: dict, name: str = "Globex", wallet: str | None = None) -> dict:
        r = self.client.post("/api/v1/customers", json={"name": name, "wallet_address": wallet}, headers=m["h"])
        assert r.status_code == 201, r.text
        return r.json()

    def invoice(self, m: dict, cust: dict, number: str = "INV-1", amount: str = "100", issue: bool = True, days: int = 30) -> dict:
        r = self.client.post("/api/v1/invoices", json={
            "customer_id": cust["id"], "invoice_number": number, "amount": amount, "due_date": str(date.today() + timedelta(days=days)),
            "issue": issue, "description": "Consulting"}, headers=m["h"])
        assert r.status_code == 201, r.text
        return r.json()

    def invoice_row(self, invoice_id) -> dict:
        return self.c.execute("select * from invoices where id=%s", (invoice_id,)).fetchone()


@pytest.fixture()
def w(conn, client):
    return World(conn, client)
