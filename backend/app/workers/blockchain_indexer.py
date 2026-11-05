"""Polling indexer for BillFlow contract events (HTTP RPC; no websocket dependency).

Safety properties
* Only blocks with >= MIN_CONFIRMATIONS are scanned (reorg-resistant by depth).
* Every log is persisted then applied through `process_event` (idempotent on chain/tx/log_index).
* Each pass re-checks the stored block hash of recent events; a changed hash is flagged `reorged_at`, an audit row is
  written and the cursor rewinds so the canonical logs are re-read. Effects already applied are NOT auto-reverted (documented).
* RPC failures never advance the cursor, so a retry re-reads the same range.
Run:  python -m app.workers.blockchain_indexer
"""
from __future__ import annotations

import logging
import threading
import time

from app.core.config import Settings, get_settings
from app.core.database import close_pool, init_pool, transaction
from app.core.exceptions import AppError
from app.core.logging import setup_logging
from app.repositories import chain as chain_repo
from app.repositories import invoices as inv_repo
from app.repositories.system import audit, notify_business
from app.services.blockchain_service import BlockchainService, get_blockchain
from app.services.event_processor import process_event, retry_unprocessed

log = logging.getLogger("billflow.indexer")
CURSOR_KEY = "billflow:combined"


class Indexer:
    def __init__(self, chain: BlockchainService, settings: Settings | None = None):
        self.chain, self.s = chain, settings or chain.s

    # ── one pass ──
    def run_once(self) -> dict:
        s, client = self.s, self.chain.client
        stats = {"scanned_from": None, "scanned_to": None, "events": 0, "applied": 0, "rejected": 0, "retry": 0, "reorgs": 0}
        self.chain.assert_network()
        head = client.latest_block()
        safe_head = head - s.min_confirmations + 1
        stats["reorgs"] = self._check_reorgs(head)
        with transaction() as c:
            last = chain_repo.get_last_block(c, s.whitechain_chain_id, CURSOR_KEY)
        if last is None:
            last = (s.indexer_start_block - 1) if s.indexer_start_block is not None else safe_head - 1
            if s.indexer_start_block is None:
                log.warning("INDEXER_START_BLOCK not set: starting at the confirmed head; history before it is NOT indexed")
        start = last + 1
        while start <= safe_head:
            end = min(start + s.indexer_batch_blocks - 1, safe_head)
            logs = client.get_logs(self.chain.contract_addresses, start, end)  # raises on RPC failure -> cursor unchanged
            decoded = [e for e in (self.chain.decoder.decode(l) for l in logs) if e is not None]
            decoded.sort(key=lambda e: (e.block_number, e.log_index))
            for ev in decoded:
                out = process_event(ev, s)
                stats["events"] += 1
                if out.status in ("applied", "rejected", "retry"):
                    stats[out.status] += 1
            with transaction() as c:
                chain_repo.set_last_block(c, s.whitechain_chain_id, CURSOR_KEY, end)
            stats["scanned_from"] = stats["scanned_from"] or start
            stats["scanned_to"] = end
            start = end + 1
        retry_unprocessed(s)
        run_maintenance()
        return stats

    def _check_reorgs(self, head: int) -> int:
        s, found = self.s, 0
        with transaction() as c:
            recent = chain_repo.recent_events(c, max(0, head - s.indexer_rescan_overlap - s.min_confirmations))
        by_block: dict[int, str | None] = {}
        for e in recent:
            if e["block_number"] not in by_block:
                by_block[e["block_number"]] = self.chain.client.get_block_hash(e["block_number"])
            if by_block[e["block_number"]] not in (None, e["block_hash"]):
                found += 1
                with transaction() as c:
                    chain_repo.mark_reorged(c, e["id"])
                    audit(c, None, "chain_reorg_detected", "blockchain_event", e["id"], {"tx_hash": e["tx_hash"], "block": e["block_number"]})
                    chain_repo.set_last_block(c, s.whitechain_chain_id, CURSOR_KEY, e["block_number"] - 1)
        return found

    # ── loop ──
    def run_forever(self, stop: threading.Event | None = None) -> None:
        stop = stop or threading.Event()
        failures = 0
        while not stop.is_set():
            try:
                self.run_once()
                failures = 0
            except AppError as e:
                failures += 1
                log.warning("indexer pass failed (%s): %s", e.code, e.message)
            except Exception:  # noqa: BLE001
                failures += 1
                log.exception("indexer pass crashed")
            stop.wait(min(self.s.indexer_poll_seconds * (2 ** min(failures, 5)), 120) if failures else self.s.indexer_poll_seconds)


def run_maintenance() -> int:
    """Mark overdue invoices (idempotent) and notify the business."""
    with transaction() as c:
        rows = inv_repo.overdue_candidates(c)
        for r in rows:
            notify_business(c, r["business_id"], "invoice_overdue", f"Invoice {r['invoice_number']} is overdue")
    return len(rows)


def start_background(settings: Settings | None = None) -> threading.Event:
    """Used by the API process when INDEXER_ENABLED=true (a separate worker process is preferable in production)."""
    s = settings or get_settings()
    chain = get_blockchain(s)
    bad = {k: v for k, v in chain.preflight().items() if not v["ok"]}
    if bad:
        raise RuntimeError(f"indexer preflight failed: {bad}")
    stop = threading.Event()
    threading.Thread(target=Indexer(chain, s).run_forever, args=(stop,), daemon=True, name="billflow-indexer").start()
    return stop


def main() -> None:  # pragma: no cover
    s = get_settings()
    setup_logging(s.log_level)
    init_pool(s.database_url)
    try:
        chain = get_blockchain(s)
        bad = {k: v for k, v in chain.preflight().items() if not v["ok"]}
        if bad:
            raise SystemExit(f"Preflight failed, refusing to index: {bad}")
        Indexer(chain, s).run_forever()
    finally:
        close_pool()


if __name__ == "__main__":  # pragma: no cover
    main()
