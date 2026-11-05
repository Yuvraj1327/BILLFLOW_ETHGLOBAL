"""blockchain_events / blockchain_transactions / indexer_state persistence."""
from __future__ import annotations

from psycopg import Connection
from psycopg.types.json import Jsonb

from app.services.blockchain_service import DecodedEvent


def insert_event(c: Connection, ev: DecodedEvent) -> dict:
    """Idempotent: a replayed (chain, tx, log_index) returns the existing row untouched."""
    c.execute("""insert into blockchain_events (chain_id, contract_address, event_name, tx_hash, log_index, block_number,
                 block_hash, payload) values (%s,%s,%s,%s,%s,%s,%s,%s) on conflict (chain_id, tx_hash, log_index) do nothing""",
              (ev.chain_id, ev.contract, ev.name, ev.tx_hash, ev.log_index, ev.block_number, ev.block_hash, Jsonb(ev.args)))
    return c.execute("""select * from blockchain_events where chain_id=%s and tx_hash=%s and log_index=%s for update""",
                     (ev.chain_id, ev.tx_hash, ev.log_index)).fetchone()


def mark_event(c: Connection, event_id, processed: bool, error: str | None) -> None:
    if processed:
        c.execute("update blockchain_events set processed_at=now(), process_error=%s, attempts=attempts+1 where id=%s",
                  (error, event_id))
    else:
        c.execute("update blockchain_events set process_error=%s, attempts=attempts+1 where id=%s", (error, event_id))


def unprocessed_events(c: Connection, limit: int = 100, max_attempts: int = 200) -> list[dict]:
    return c.execute("""select * from blockchain_events where processed_at is null and reorged_at is null and attempts < %s
                        order by block_number, log_index limit %s""", (max_attempts, limit)).fetchall()


def upsert_tx(c: Connection, tx_hash: str, chain_id: int, kind: str, status: str, *, from_address=None, to_address=None,
              block_number=None, block_hash=None, confirmations=0, error=None, related_type=None, related_id=None) -> dict:
    return c.execute("""insert into blockchain_transactions (tx_hash, chain_id, kind, status, from_address, to_address,
                        block_number, block_hash, confirmations, error, related_type, related_id,
                        confirmed_at)
                        values (%s,%s,%s,%s::tx_status,%s,%s,%s,%s,%s,%s,%s,%s, case when %s='CONFIRMED' then now() end)
                        on conflict (tx_hash) do update set
                          status = case when blockchain_transactions.status='CONFIRMED' and excluded.status='SUBMITTED'
                                        then blockchain_transactions.status else excluded.status end,
                          block_number=coalesce(excluded.block_number, blockchain_transactions.block_number),
                          block_hash=coalesce(excluded.block_hash, blockchain_transactions.block_hash),
                          confirmations=greatest(excluded.confirmations, blockchain_transactions.confirmations),
                          error=excluded.error,
                          related_type=coalesce(excluded.related_type, blockchain_transactions.related_type),
                          related_id=coalesce(excluded.related_id, blockchain_transactions.related_id),
                          confirmed_at=coalesce(blockchain_transactions.confirmed_at, excluded.confirmed_at)
                        returning *""",
                     (tx_hash, chain_id, kind, status, from_address, to_address, block_number, block_hash, confirmations,
                      error, related_type, related_id, status)).fetchone()


def mark_tx_verified(c: Connection, tx_hash: str) -> None:
    c.execute("update blockchain_transactions set verified_at=coalesce(verified_at, now()) where tx_hash=%s", (tx_hash,))


def get_tx(c: Connection, tx_hash: str) -> dict | None:
    return c.execute("select * from blockchain_transactions where tx_hash=%s", (tx_hash,)).fetchone()


def get_last_block(c: Connection, chain_id: int, address: str) -> int | None:
    r = c.execute("select last_block from indexer_state where chain_id=%s and contract_address=%s", (chain_id, address)).fetchone()
    return r["last_block"] if r else None


def set_last_block(c: Connection, chain_id: int, address: str, block: int) -> None:
    c.execute("""insert into indexer_state (chain_id, contract_address, last_block) values (%s,%s,%s)
                 on conflict (chain_id, contract_address) do update set last_block=excluded.last_block, updated_at=now()""",
              (chain_id, address, block))


def recent_events(c: Connection, from_block: int) -> list[dict]:
    return c.execute("select id, tx_hash, log_index, block_number, block_hash from blockchain_events "
                     "where block_number >= %s and reorged_at is null order by block_number", (from_block,)).fetchall()


def mark_reorged(c: Connection, event_id) -> None:
    c.execute("update blockchain_events set reorged_at=now(), process_error='block hash changed (reorg)' where id=%s", (event_id,))
