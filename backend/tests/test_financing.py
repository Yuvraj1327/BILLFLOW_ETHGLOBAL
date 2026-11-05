from datetime import date, datetime, timedelta, timezone

import pytest
from eth_account import Account

from app.core.config import get_settings
from app.services.event_processor import retry_unprocessed
from tests.helpers import FINANCING, h32, make_log, pdf_bytes

API = "/api/v1"
MERCHANT_WALLET = "0x" + "aa" * 20
INVESTOR_WALLET = Account.create().address.lower()
PAYER = "0x" + "99" * 20
ZERO = "0x" + "00" * 20
ACK = {"evidence_ref": "email-thread-42", "acknowledged_at": "2026-11-01T10:00:00Z", "acknowledged_by": "CFO Globex"}
NOTICE = {"reference": "assignment-letter-7"}


@pytest.fixture()
def env(w, client):
    m = w.merchant(MERCHANT_WALLET); c = w.customer(m, wallet=PAYER)
    inv = w.invoice(m, c, amount="100", days=30)
    adm = w.user("admin"); investor = w.user("investor"); w.set_wallet(investor, INVESTOR_WALLET)
    return {"m": m, "inv": inv, "adm": adm, "investor": investor, "w": w}


def submit(client, e, advance="90"):
    return client.post(f"{API}/financing/submit", json={"invoice_id": e["inv"]["id"], "advance": advance}, headers=e["m"]["h"])


def approve(client, e, offer_id):
    return client.post(f"{API}/financing/offers/{offer_id}/verify", json={"decision": "approve", "debtor_ack": ACK, "assignment_notice": NOTICE},
                       headers=e["adm"]["h"])


class Chain:
    """Emits genuine ABI-encoded InvoiceFinancing events for an offer, one tx each."""
    def __init__(self, chain, client, e, offer, onchain_id=1):
        self.chain, self.client, self.e, self.o, self.id, self.n, self.block = chain, client, e, offer, onchain_id, 0, 100

    def emit(self, name, args, who=None):
        self.n += 1; self.block += 1
        t = h32(f"fin-{self.o['id']}-{self.n}")
        self.chain.add(t, [make_log("financing", FINANCING, name, args, tx_hash=t, log_index=0)], block=self.block, to=FINANCING)
        return t

    def verify(self, t, h=None):
        return self.client.post(f"{API}/financing/verify-transaction", json={"tx_hash": t}, headers=h or self.e["adm"]["h"])

    def a(self, **kw):
        inv = self.e["inv"]
        base = {"invoiceId": self.id}
        return {**base, **kw}

    def registered(self, **over):
        inv = self.e["inv"]
        args = {"invoiceId": self.id, "invoiceHash": inv["invoice_hash"], "business": MERCHANT_WALLET, "debtor": PAYER,
                "debtorRef": h32("debtor"), "documentHash": h32("doc"), "faceValue": 100_000_000, "issueDate": 1, "dueDate": 2,
                "registeredBy": MERCHANT_WALLET, **over}
        return self.emit("InvoiceRegistered", args)

    def verified(self, ack_hash):
        return self.emit("InvoiceVerified", {"invoiceId": self.id, "verifier": MERCHANT_WALLET, "debtorAckRef": ack_hash})

    def created(self, advance=90_000_000, **over):
        dl = int((datetime.now(timezone.utc) + timedelta(hours=48)).timestamp())
        return self.emit("OfferCreated", {"invoiceId": self.id, "business": MERCHANT_WALLET, "faceValue": 100_000_000, "advance": advance,
                                          "discountBps": 1000, "dueDate": 2, "fundingDeadline": dl, **over})

    def funded(self, investor=INVESTOR_WALLET, advance=90_000_000):
        return self.emit("OfferFunded", {"invoiceId": self.id, "investor": investor, "business": MERCHANT_WALLET, "advance": advance})

    def repaid(self, amount=100_000_000):
        return self.emit("OfferRepaid", {"invoiceId": self.id, "payer": PAYER, "investor": INVESTOR_WALLET, "amount": amount})

    def settled(self):
        return self.emit("OfferSettled", {"invoiceId": self.id, "investor": INVESTOR_WALLET})


def offer_status(client, e, oid):
    return client.get(f"{API}/financing/offers/{oid}", headers=e["adm"]["h"]).json()


def to_listed(client, chain, e):
    o = submit(client, e).json()
    ap = approve(client, e, o["id"]).json()
    ch = Chain(chain, client, e, o)
    assert ch.verify(ch.registered()).json()["stage"] == "verified"
    full = client.get(f"{API}/financing/offers/{o['id']}", headers=e["adm"]["h"]).json()
    ack_hash = e["w"].c.execute("select debtor_ack_hash from financing_offers where id=%s", (o["id"],)).fetchone()["debtor_ack_hash"]
    assert ch.verify(ch.verified(ack_hash)).json()["stage"] == "verified"
    assert ch.verify(ch.created()).json()["stage"] == "verified"
    return o, ch


# ───────────── submission ─────────────
def test_submit_creates_requested_and_nothing_onchain(env, client, conn):
    r = submit(client, env)
    assert r.status_code == 201, r.text
    b = r.json()
    assert b["status"] == "REQUESTED" and b["display_status"] == "SUBMITTED" and b["discount_bps"] == 1000
    assert b["advance"] == "90" and b["face_value"] == "100" and "Testnet" in b["disclosure"]
    assert b["onchain_offer_id"] is None
    assert conn.execute("select count(*) n from notifications where type='financing_submitted'").fetchone()["n"] == 1  # admin notified
    assert conn.execute("select count(*) n from audit_logs where action='financing_submitted'").fetchone()["n"] == 1


def test_submit_validation(env, client, w, conn):
    assert submit(client, env, "100").status_code == 400  # advance == face
    assert submit(client, env, "0").status_code == 400
    assert submit(client, env, "79.99").json()["error"]["code"] == "discount_too_high"  # > 20%
    assert submit(client, env, "80").status_code == 201  # exactly at the cap
    assert submit(client, env, "90").status_code == 409  # one financing per invoice
    m2 = w.merchant("0x" + "bb" * 20, verified=False); c2 = w.customer(m2); i2 = w.invoice(m2, c2)
    r = client.post(f"{API}/financing/submit", json={"invoice_id": i2["id"], "advance": "90"}, headers=m2["h"])
    assert r.status_code == 403 and r.json()["error"]["code"] == "business_not_verified"
    r = client.post(f"{API}/financing/submit", json={"invoice_id": i2["id"], "advance": "90"}, headers=env["m"]["h"])
    assert r.status_code == 404  # someone else's invoice
    draft = w.invoice(env["m"], w.customer(env["m"], "Other"), number="D1", issue=False)
    assert client.post(f"{API}/financing/submit", json={"invoice_id": draft["id"], "advance": "9"}, headers=env["m"]["h"]).status_code == 409


def test_only_merchants_submit(env, client):
    for who in ("investor", "adm"):
        r = client.post(f"{API}/financing/submit", json={"invoice_id": env["inv"]["id"], "advance": "90"}, headers=env[who]["h"])
        assert r.status_code == 403


def test_discount_cap_follows_platform_setting(env, client):
    r = client.put(f"{API}/admin/settings/max_discount_bps", json={"value": 500}, headers=env["adm"]["h"])
    assert r.status_code == 200
    assert submit(client, env, "90").json()["error"]["code"] == "discount_too_high"
    assert submit(client, env, "95").status_code == 201


# ───────────── verification workflow ─────────────
def test_review_workflow_and_invalid_transitions(env, client):
    o = submit(client, env).json()
    h = env["adm"]["h"]
    for who in ("m", "investor"):
        assert client.post(f"{API}/financing/offers/{o['id']}/verify", json={"decision": "approve"}, headers=env[who]["h"]).status_code == 403
    assert client.post(f"{API}/financing/offers/{o['id']}/verify", json={"decision": "approve"}, headers=h).json()["error"]["code"] == "evidence_required"
    assert client.post(f"{API}/financing/offers/{o['id']}/verify", json={"decision": "reject"}, headers=h).json()["error"]["code"] == "notes_required"
    assert client.post(f"{API}/financing/offers/{o['id']}/verify", json={"decision": "start_review"}, headers=h).json()["status"] == "UNDER_REVIEW"
    ok = approve(client, env, o["id"])
    assert ok.status_code == 200 and ok.json()["status"] == "APPROVED" and ok.json()["debtor_ack"]["evidence_ref"] == "email-thread-42"
    assert client.get(f"{API}/invoices/{env['inv']['id']}", headers=env["m"]["h"]).json()["review_status"] == "verified"
    # APPROVED cannot go back to review or be approved again
    assert client.post(f"{API}/financing/offers/{o['id']}/verify", json={"decision": "start_review"}, headers=h).status_code == 409
    rej = client.post(f"{API}/financing/offers/{o['id']}/verify", json={"decision": "reject", "notes": "debtor disputes"}, headers=h)
    assert rej.json()["status"] == "REJECTED"
    assert approve(client, env, o["id"]).status_code == 409  # terminal
    # nobody can set LISTED/FUNDED/SETTLED through the API
    for bad in ("list", "listed", "fund", "funded", "settled"):
        assert client.post(f"{API}/financing/offers/{o['id']}/verify", json={"decision": bad}, headers=h).status_code == 422


def test_publish_plan_is_instructions_only(env, client, conn):
    o = submit(client, env).json()
    assert client.post(f"{API}/financing/offers/{o['id']}/publish", headers=env["adm"]["h"]).json()["error"]["code"] == "not_approved"
    approve(client, env, o["id"])
    assert client.post(f"{API}/financing/offers/{o['id']}/publish", headers=env["adm"]["h"]).json()["error"]["code"] == "document_required"
    up = client.post(f"{API}/invoices/{env['inv']['id']}/upload", files={"file": ("i.pdf", pdf_bytes(), "application/pdf")}, headers=env["m"]["h"]).json()
    r = client.post(f"{API}/financing/offers/{o['id']}/publish", headers=env["adm"]["h"])
    assert r.status_code == 200, r.text
    p = r.json()
    step = p["next_step"]
    assert step["function"] == "registerInvoice" and step["contract"].lower() == FINANCING
    a = step["args"]["p"]
    assert a["documentHash"] == up["document_hash"] and a["business"] == MERCHANT_WALLET and a["faceValue"] == "100000000"
    assert a["invoiceHash"] == env["inv"]["invoice_hash"] and a["debtor"] == PAYER
    assert p["remaining_steps"] == ["register", "verify", "list"] and p["status"] == "APPROVED"  # still APPROVED: nothing was sent
    assert conn.execute("select status from financing_offers where id=%s", (o["id"],)).fetchone()["status"] == "APPROVED"
    # other merchant cannot get the plan
    other = env["w"].merchant("0x" + "bb" * 20)
    assert client.post(f"{API}/financing/offers/{o['id']}/publish", headers=other["h"]).status_code == 404
    assert client.post(f"{API}/financing/offers/{o['id']}/publish", headers=env["investor"]["h"]).status_code == 404


def test_cancel_before_and_after_registration(env, client, chain):
    o = submit(client, env).json()
    assert client.post(f"{API}/financing/offers/{o['id']}/cancel", headers=env["investor"]["h"]).status_code == 404
    assert client.post(f"{API}/financing/offers/{o['id']}/cancel", headers=env["m"]["h"]).json()["status"] == "CANCELLED"


# ───────────── on-chain events are authoritative ─────────────
def test_full_lifecycle_to_settled(env, client, chain, conn):
    o, ch = to_listed(client, chain, env)
    assert offer_status(client, env, o["id"])["status"] == "LISTED"
    assert offer_status(client, env, o["id"])["display_status"] == "AVAILABLE"
    f = ch.verify(ch.funded())
    assert f.json()["stage"] == "verified"
    st = offer_status(client, env, o["id"])
    assert st["status"] == "FUNDED" and st["display_status"] == "ACTIVE"
    inv = client.get(f"{API}/financing/investments", headers=env["investor"]["h"]).json()
    assert inv["total"] == 1 and inv["items"][0]["amount"] == "90" and inv["items"][0]["expected_repayment"] == "100"
    assert inv["items"][0]["status"] == "CONFIRMED"
    # merchant also sees it; invoice is untouched until settlement
    assert client.get(f"{API}/financing/investments", headers=env["m"]["h"]).json()["total"] == 1
    assert client.get(f"{API}/invoices/{env['inv']['id']}", headers=env["m"]["h"]).json()["status"] == "PENDING"
    assert client.get(f"{API}/financing/settlements", headers=env["investor"]["h"]).json()["total"] == 0
    assert ch.verify(ch.repaid()).json()["stage"] == "verified"
    assert ch.verify(ch.settled()).json()["stage"] == "verified"
    assert offer_status(client, env, o["id"])["status"] == "SETTLED"
    s = client.get(f"{API}/financing/settlements", headers=env["investor"]["h"]).json()
    assert s["total"] == 1 and s["items"][0]["repayment_amount"] == "100" and s["items"][0]["status"] == "SETTLED"
    assert client.get(f"{API}/invoices/{env['inv']['id']}", headers=env["m"]["h"]).json()["status"] == "PAID"
    iid = inv["items"][0]["id"]
    assert client.get(f"{API}/financing/investments/{iid}", headers=env["investor"]["h"]).status_code == 200
    assert client.get(f"{API}/financing/invoices/{env['inv']['id']}", headers=env["m"]["h"]).json()["status"] == "SETTLED"
    pf = client.get(f"{API}/investors/me/portfolio", headers=env["investor"]["h"]).json()
    assert pf["settled_principal"] == "90" and pf["returned"] == "100"


def test_duplicate_funding_event_counts_once(env, client, chain, conn):
    o, ch = to_listed(client, chain, env)
    t = ch.funded()
    for _ in range(3):
        assert ch.verify(t).json()["stage"] == "verified"
    assert conn.execute("select count(*) n from investments").fetchone()["n"] == 1
    # a second, different funding tx for the same offer is a duplicate too (one funder)
    t2 = ch.funded()
    b = ch.verify(t2).json()
    assert conn.execute("select count(*) n from investments").fetchone()["n"] == 1


def test_funding_before_listing_is_retried_not_applied(env, client, chain, conn):
    o = submit(client, env).json(); approve(client, env, o["id"])
    ch = Chain(chain, client, env, o)
    ch.verify(ch.registered())
    b = ch.verify(ch.funded()).json()
    assert b["stage"] == "confirmed" and "listing event not processed yet" in b["detail"]
    assert offer_status(client, env, o["id"])["status"] == "APPROVED"
    assert conn.execute("select count(*) n from investments").fetchone()["n"] == 0


def test_funding_by_unlinked_wallet_parks_then_applies(env, client, chain, conn):
    o, ch = to_listed(client, chain, env)
    stranger = Account.create().address.lower()
    t = ch.funded(investor=stranger)
    b = ch.verify(t).json()
    assert b["stage"] == "confirmed" and "investor_wallet_not_linked" in b["detail"]
    assert conn.execute("select count(*) n from investments").fetchone()["n"] == 0
    assert conn.execute("select processed_at from blockchain_events where event_name='OfferFunded'").fetchone()["processed_at"] is None
    late = env["w"].user("investor"); env["w"].set_wallet(late, stranger)
    assert retry_unprocessed(get_settings()) == 1
    assert offer_status(client, env, o["id"])["status"] == "FUNDED"
    assert conn.execute("select investor_id from investments").fetchone()["investor_id"] == late["id"]


@pytest.mark.parametrize("over,stage", [
    ({"faceValue": 99_000_000}, "rejected"), ({"business": "0x" + "ee" * 20}, "rejected"),
    ({"invoiceHash": h32("nope")}, "verified"),  # unknown to BillFlow => ignored as a harmless no-op, never linked
])
def test_bad_registration_never_links(env, client, chain, over, stage):
    o = submit(client, env).json(); approve(client, env, o["id"])
    ch = Chain(chain, client, env, o)
    b = ch.verify(ch.registered(**over)).json()
    assert b["stage"] == stage, b
    assert offer_status(client, env, o["id"])["onchain_offer_id"] is None


def test_offer_terms_mismatch_rejected(env, client, chain):
    o = submit(client, env).json(); approve(client, env, o["id"])
    ch = Chain(chain, client, env, o)
    ch.verify(ch.registered())
    assert ch.verify(ch.created(advance=95_000_000)).json()["stage"] == "rejected"
    assert offer_status(client, env, o["id"])["status"] == "APPROVED"


def test_wrong_repayment_amount_rejected(env, client, chain):
    o, ch = to_listed(client, chain, env)
    ch.verify(ch.funded())
    assert ch.verify(ch.repaid(amount=50_000_000)).json()["stage"] == "rejected"


def test_event_from_foreign_contract_cannot_list(env, client, chain):
    o = submit(client, env).json(); approve(client, env, o["id"])
    ch = Chain(chain, client, env, o)
    t = h32("evil")
    chain.add(t, [make_log("financing", "0x" + "66" * 20, "InvoiceRegistered", {
        "invoiceId": 1, "invoiceHash": env["inv"]["invoice_hash"], "business": MERCHANT_WALLET, "debtor": PAYER, "debtorRef": h32("d"),
        "documentHash": h32("x"), "faceValue": 100_000_000, "issueDate": 1, "dueDate": 2, "registeredBy": MERCHANT_WALLET}, tx_hash=t)],
              to="0x" + "66" * 20)
    assert ch.verify(t).json()["stage"] == "rejected"
    assert offer_status(client, env, o["id"])["onchain_offer_id"] is None


def test_unconfirmed_financing_tx_changes_nothing(env, client, chain):
    o = submit(client, env).json(); approve(client, env, o["id"])
    ch = Chain(chain, client, env, o)
    t = ch.registered()
    chain.head = 101  # 1 confirmation only
    assert ch.verify(t).json()["stage"] == "submitted"
    assert offer_status(client, env, o["id"])["onchain_offer_id"] is None


def test_cancel_after_registration_requires_chain(env, client, chain):
    o = submit(client, env).json(); approve(client, env, o["id"])
    ch = Chain(chain, client, env, o); ch.verify(ch.registered())
    r = client.post(f"{API}/financing/offers/{o['id']}/cancel", headers=env["m"]["h"])
    assert r.status_code == 409 and r.json()["error"]["code"] == "registered_onchain"
    assert ch.verify(ch.emit("InvoiceCancelled", {"invoiceId": 1, "by": MERCHANT_WALLET})).json()["stage"] == "verified"
    assert offer_status(client, env, o["id"])["status"] == "CANCELLED"


def test_expiry_and_default_events(env, client, chain):
    o, ch = to_listed(client, chain, env)
    ch.verify(ch.funded())
    assert ch.verify(ch.emit("OfferDefaulted", {"invoiceId": 1, "by": MERCHANT_WALLET})).json()["stage"] == "verified"
    st = offer_status(client, env, o["id"])
    assert st["status"] == "DEFAULTED" and st["display_status"] == "OVERDUE" and st["is_overdue"] is True


# ───────────── access control ─────────────
def test_investor_visibility_and_privacy(env, client, chain):
    o = submit(client, env).json()
    inv_h = env["investor"]["h"]
    assert client.get(f"{API}/financing/offers", headers=inv_h).json()["total"] == 0  # REQUESTED is not public
    assert client.get(f"{API}/financing/offers/{o['id']}", headers=inv_h).status_code == 404
    approve(client, env, o["id"])
    ch = Chain(chain, client, env, o); to_listed_chain = None
    ch.verify(ch.registered())
    ack = env["w"].c.execute("select debtor_ack_hash from financing_offers where id=%s", (o["id"],)).fetchone()["debtor_ack_hash"]
    ch.verify(ch.verified(ack)); ch.verify(ch.created())
    lst = client.get(f"{API}/financing/offers", headers=inv_h).json()
    assert lst["total"] == 1 and lst["items"][0]["status"] == "LISTED"
    one = client.get(f"{API}/financing/offers/{o['id']}", headers=inv_h).json()
    assert one["debtor_ack"] is None and one["assignment_notice"] is None and one["review_notes"] is None  # review evidence hidden
    assert client.get(f"{API}/financing/offers/{o['id']}", headers=env["m"]["h"]).json()["debtor_ack"]["evidence_ref"] == "email-thread-42"
    # customers have no financing access, other merchants see nothing
    cust = env["w"].user("customer")
    assert client.get(f"{API}/financing/offers", headers=cust["h"]).status_code == 403
    other = env["w"].merchant("0x" + "bb" * 20)
    assert client.get(f"{API}/financing/offers", headers=other["h"]).json()["total"] == 0
    assert client.get(f"{API}/financing/offers/{o['id']}", headers=other["h"]).status_code == 404
    assert client.get(f"{API}/financing/invoices/{env['inv']['id']}", headers=other["h"]).status_code == 404


def test_other_investor_cannot_read_investment(env, client, chain):
    o, ch = to_listed(client, chain, env)
    ch.verify(ch.funded())
    iid = client.get(f"{API}/financing/investments", headers=env["investor"]["h"]).json()["items"][0]["id"]
    other = env["w"].user("investor")
    assert client.get(f"{API}/financing/investments/{iid}", headers=other["h"]).status_code == 404
    assert client.get(f"{API}/financing/investments", headers=other["h"]).json()["total"] == 0


def test_stranger_gets_redacted_financing_verify(env, client, chain):
    o = submit(client, env).json(); approve(client, env, o["id"])
    ch = Chain(chain, client, env, o); t = ch.registered()
    stranger = env["w"].merchant("0x" + "bb" * 20)
    b = ch.verify(t, stranger["h"]).json()
    assert b["events"] == [] and b["offer_ids"] == []
