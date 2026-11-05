"""Postgres access for the trusted backend. Sync psycopg3 pool; every write path uses a transaction."""
from __future__ import annotations

from contextlib import contextmanager
from typing import Iterator

import psycopg
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

_pool: ConnectionPool | None = None


def init_pool(dsn: str, min_size: int = 1, max_size: int = 10) -> ConnectionPool:
    global _pool
    if _pool is not None:
        _pool.close()
    _pool = ConnectionPool(dsn, min_size=min_size, max_size=max_size, kwargs={"row_factory": dict_row, "autocommit": True},
                           open=True)
    _pool.wait()
    return _pool


def close_pool() -> None:
    global _pool
    if _pool is not None:
        _pool.close()
        _pool = None


def pool_ready() -> bool:
    return _pool is not None


@contextmanager
def transaction() -> Iterator[psycopg.Connection]:
    """One connection, one transaction: commit on success, roll back on any exception."""
    if _pool is None:
        raise RuntimeError("database pool not initialised")
    with _pool.connection() as conn:
        with conn.transaction():
            yield conn


def ping() -> bool:
    with transaction() as c:
        return c.execute("select 1 as ok").fetchone()["ok"] == 1
