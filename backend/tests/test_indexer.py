from datetime import date, timedelta

import pytest

from app.core.config import get_settings
from app.core.exceptions import AppError
from app.services.blockchain_service import get_blockchain
from app.workers.blockchain_indexer import CURSOR_KEY, Indexer, run_maintenance
from tests.helpers import FINANCING, PAYMENTS, USDT, erc20_transfer, h32, invoice_paid, make_log

API = "/api/v1"
MW = "0x" + "aa" * 20
PAYER = "0x" + "99" * 20


@pytest.fixture()
def idx(chain):
    s = get_settings().model_copy(update={"indexer_start_block": 1})
    return Indexer(get_blockchain(s), s)


@pytest.fixture()
def inv(w):
    m = w.merchant(MW); c = w.customer(m)
    return m, w.invoice(m, c, amount="100")


def pay_tx(chain, inv, n, block, amount=100_000_000, total=100_000_000, **tamper):
    t = h32(f"idx-{n}")
    i = {**inv, **tamper}
    chain.add(t, [erc20_transfer(PAYER, MW, amount, tx_hash=t, log_index=0),
                  invoice_paid(i, PAYER, MW, amount, total, tx_hash=t, log_index=1)], block=block)
    return t


def cursor(conn):
    r = conn.execute("select last_block from indexer_state where contract_address=%s", (CURSOR_KEY,)).fetchone()
    return r["last_block"] if r else None


def test_indexer_applies_payment_without_any_api_call(idx, inv, chain, client, conn):
    m, i = inv
    pay_tx(chain, i, 1, 100)
    stats = idx.run_once()
    assert stats["applied"] == 1 and stats["scanned_to"] == 198
    assert client.get(f"{API}/invoices/{i['id']}", headers=m["h"]).json()["status"] == "PAID"
    assert cursor(conn) == 198


def test_rerun_and_overlap_are_idempotent(idx, inv, chain, conn):
    m, i = inv
    pay_tx(chain, i, 1, 100)
    idx.run_once()
    conn.execute("delete from indexer_state")  # force a full re-scan of the same range
    stats = idx.run_once()
    assert stats["applied"] == 0 and stats["events"] >= 1
    assert conn.execute("select count(*) n from payments").fetchone()["n"] == 1
    assert conn.execute("select count(*) n from blockchain_events where event_name='InvoicePaid'").fetchone()["n"] == 1


def test_only_confirmed_blocks_are_scanned(idx, inv, chain, client, conn):
    m, i = inv
    pay_tx(chain, i, 1, 199)  # head=200, MIN_CONFIRMATIONS=3 -> safe head 198
    assert idx.run_once()["events"] == 0
    chain.head = 201
    assert idx.run_once()["applied"] == 1


def test_rpc_failure_does_not_advance_cursor(idx, inv, chain, conn):
    m, i = inv
    pay_tx(chain, i, 1, 100)
    idx.run_once()
    before = cursor(conn)
    chain.head = 300; chain.fail = True
    with pytest.raises(AppError):
        idx.run_once()
    assert cursor(conn) == before
    chain.fail = False
    idx.run_once()
    assert cursor(conn) == 298


def test_wrong_network_stops_indexer(idx, chain):
    chain.cid = 2625
    with pytest.raises(AppError) as e:
        idx.run_once()
    assert e.value.code == "wrong_network"


def test_forged_event_recorded_but_not_applied(idx, inv, chain, client, conn):
    m, i = inv
    pay_tx(chain, i, 1, 100, invoice_hash=h32("forged"))
    s = idx.run_once()
    assert s["rejected"] == 1
    assert client.get(f"{API}/invoices/{i['id']}", headers=m["h"]).json()["status"] == "PENDING"
    ev = conn.execute("select processed_at, process_error from blockchain_events where event_name='InvoicePaid'").fetchone()
    assert ev["processed_at"] is not None and "invoice_hash_mismatch" in ev["process_error"]


def test_reorg_is_flagged_and_cursor_rewound(idx, inv, chain, client, conn):
    m, i = inv
    pay_tx(chain, i, 1, 195)  # inside the re-check window (head - overlap - confirmations)
    idx.run_once()
    chain.block_hashes[195] = h32("different-block-after-reorg")
    stats = idx.run_once()
    assert stats["reorgs"] == 1
    assert conn.execute("select reorged_at from blockchain_events where event_name='InvoicePaid'").fetchone()["reorged_at"] is not None
    assert conn.execute("select count(*) n from audit_logs where action='chain_reorg_detected'").fetchone()["n"] == 1
    assert conn.execute("select count(*) n from payments").fetchone()["n"] == 1  # never double-counted
    assert cursor(conn) == 198  # rewound to 194 then the canonical range was re-read in the same pass


def test_lifecycle_in_one_pass_and_order(idx, w, chain, client, conn):
    m = w.merchant(MW); c = w.customer(m, wallet=PAYER); i = w.invoice(m, c)
    adm = w.user("admin"); investor = w.user("investor"); inv_wallet = "0x" + "55" * 20; w.set_wallet(investor, inv_wallet)
    o = client.post(f"{API}/financing/submit", json={"invoice_id": i["id"], "advance": "90"}, headers=m["h"]).json()
    client.post(f"{API}/financing/offers/{o['id']}/verify", headers=adm["h"], json={
        "decision": "approve", "debtor_ack": {"evidence_ref": "ref-1", "acknowledged_at": "2026-11-01T00:00:00Z"},
        "assignment_notice": {"reference": "n-1"}})
    ack = conn.execute("select debtor_ack_hash from financing_offers").fetchone()["debtor_ack_hash"]
    import datetime as dt
    dl = int((dt.datetime.now(dt.timezone.utc) + dt.timedelta(hours=24)).timestamp())
    seq = [("InvoiceRegistered", {"invoiceId": 7, "invoiceHash": i["invoice_hash"], "business": MW, "debtor": PAYER, "debtorRef": h32("d"),
                                  "documentHash": h32("doc"), "faceValue": 100_000_000, "issueDate": 1, "dueDate": 2, "registeredBy": MW}),
           ("InvoiceVerified", {"invoiceId": 7, "verifier": MW, "debtorAckRef": ack}),
           ("OfferCreated", {"invoiceId": 7, "business": MW, "faceValue": 100_000_000, "advance": 90_000_000, "discountBps": 1000, "dueDate": 2, "fundingDeadline": dl}),
           ("OfferFunded", {"invoiceId": 7, "investor": inv_wallet, "business": MW, "advance": 90_000_000}),
           ("OfferRepaid", {"invoiceId": 7, "payer": PAYER, "investor": inv_wallet, "amount": 100_000_000}),
           ("OfferSettled", {"invoiceId": 7, "investor": inv_wallet})]
    # all in ONE block, so only log_index orders them; add them in scrambled order to prove sorting
    t = h32("one-block")
    logs = [make_log("financing", FINANCING, n, a, tx_hash=t, log_index=k, block=120) for k, (n, a) in enumerate(seq)]
    chain.add(t, list(reversed(logs)), block=120, to=FINANCING)
    for lg, k in zip(chain.receipts[t].logs, reversed(range(len(logs)))):
        lg.log_index = k
    stats = idx.run_once()
    assert stats["applied"] == 6, stats
    st = client.get(f"{API}/financing/offers/{o['id']}", headers=adm["h"]).json()
    assert st["status"] == "SETTLED" and st["onchain_offer_id"] == "7"
    assert client.get(f"{API}/invoices/{i['id']}", headers=m["h"]).json()["status"] == "PAID"


def test_maintenance_marks_overdue_only_unpaid(w, client, conn):
    m = w.merchant(MW); c = w.customer(m)
    a = w.invoice(m, c, number="old"); b = w.invoice(m, c, number="paid")
    conn.execute("alter table invoices disable trigger user")
    conn.execute("update invoices set issue_date=current_date - 40, due_date=current_date - 5")
    conn.execute("update invoices set status='PAID', paid_amount_base=amount_base where id=%s", (b["id"],))
    conn.execute("alter table invoices enable trigger user")
    assert run_maintenance() == 1
    assert client.get(f"{API}/invoices/{a['id']}", headers=m["h"]).json()["status"] == "OVERDUE"
    assert client.get(f"{API}/invoices/{b['id']}", headers=m["h"]).json()["status"] == "PAID"
    assert run_maintenance() == 0
    assert conn.execute("select count(*) n from notifications where type='invoice_overdue'").fetchone()["n"] >= 1
