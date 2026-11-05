import pytest
from eth_account import Account
from eth_account.messages import encode_typed_data

from tests.helpers import (CHAIN_ID, FINANCING, OTHER_TOKEN, PAYMENTS, SIGNER_KEY, USDT, erc20_transfer, h32, invoice_paid)
from tests.helpers import make_log

API = "/api/v1"
MERCHANT_WALLET = "0x" + "aa" * 20
PAYER = Account.create().address.lower()


def tx(n: int) -> str:
    return h32(f"tx-{n}")


@pytest.fixture()
def setup(w, client):
    m = w.merchant(MERCHANT_WALLET); c = w.customer(m); inv = w.invoice(m, c, amount="100")
    return m, inv


def pay(chain, inv, n=1, amount=100_000_000, total=None, *, token=USDT, contract=PAYMENTS, block=100, payer=PAYER, merchant=MERCHANT_WALLET, **tamper):
    i = {**inv, **tamper}
    logs = [erc20_transfer(payer, merchant, amount, address=token, tx_hash=tx(n), log_index=0),
            invoice_paid(i, payer, merchant, amount, total if total is not None else amount, address=contract, tx_hash=tx(n), log_index=1)]
    chain.add(tx(n), logs, block=block)
    return tx(n)


def verify(client, h, tx_hash):
    return client.post(f"{API}/payments/verify", json={"tx_hash": tx_hash}, headers=h)


def test_valid_payment_marks_paid(setup, client, chain, w):
    m, inv = setup
    t = pay(chain, inv)
    r = verify(client, m["h"], t)
    assert r.status_code == 200, r.text
    b = r.json()
    assert b["stage"] == "verified" and b["confirmations"] >= 3 and len(b["payment_ids"]) == 1
    got = client.get(f"{API}/invoices/{inv['id']}", headers=m["h"]).json()
    assert got["status"] == "PAID" and got["paid_amount"] == "100" and got["payment_tx_hash"] == t
    assert got["payment_explorer_url"].endswith(f"/tx/{t}")
    st = client.get(f"{API}/invoices/{inv['id']}/payment-status", headers=m["h"]).json()
    assert st["remaining_amount"] == "0" and st["payable"] is False and st["payments"][0]["tx_hash"] == t


def test_partial_then_full(setup, client, chain):
    m, inv = setup
    verify(client, m["h"], pay(chain, inv, 1, 40_000_000, 40_000_000))
    assert client.get(f"{API}/invoices/{inv['id']}", headers=m["h"]).json()["status"] == "PARTIALLY_PAID"
    verify(client, m["h"], pay(chain, inv, 2, 60_000_000, 100_000_000, block=101))
    got = client.get(f"{API}/invoices/{inv['id']}", headers=m["h"]).json()
    assert got["status"] == "PAID" and got["paid_amount_base"] == "100000000"
    assert client.get(f"{API}/payments/invoice/{inv['id']}", headers=m["h"]).json().__len__() == 2


def test_duplicate_submission_is_idempotent(setup, client, chain, conn):
    m, inv = setup
    t = pay(chain, inv)
    for _ in range(3):
        assert verify(client, m["h"], t).json()["stage"] == "verified"
    assert conn.execute("select count(*) n from payments").fetchone()["n"] == 1
    assert conn.execute("select paid_amount_base from invoices where id=%s", (inv["id"],)).fetchone()["paid_amount_base"] == 100_000_000


def test_frontend_success_claim_is_ignored(setup, client, chain):
    """Nothing the client sends can mark an invoice paid: only verification of real chain data does."""
    m, inv = setup
    r = client.post(f"{API}/payments/verify", json={"tx_hash": tx(9), "status": "success", "paid": True}, headers=m["h"])
    assert r.status_code == 422
    r = verify(client, m["h"], tx(9))  # unknown hash
    assert r.json()["stage"] == "not_found"
    assert client.get(f"{API}/invoices/{inv['id']}", headers=m["h"]).json()["status"] == "PENDING"
    # no public/other endpoint accepts a status either
    assert client.patch(f"{API}/invoices/{inv['id']}", json={"status": "PAID"}, headers=m["h"]).status_code == 422


def test_not_enough_confirmations(setup, client, chain):
    m, inv = setup
    t = pay(chain, inv, block=199)  # head=200 -> 2 confirmations < 3
    b = verify(client, m["h"], t).json()
    assert b["stage"] == "submitted" and b["confirmations"] == 2
    assert client.get(f"{API}/invoices/{inv['id']}", headers=m["h"]).json()["status"] == "PENDING"
    chain.head = 205  # later, enough confirmations
    assert verify(client, m["h"], t).json()["stage"] == "verified"


def test_reverted_tx_failed(setup, client, chain, conn):
    m, inv = setup
    chain.add(tx(5), [], status=0, block=100)
    assert verify(client, m["h"], tx(5)).json()["stage"] == "failed"
    assert conn.execute("select status from blockchain_transactions where tx_hash=%s", (tx(5),)).fetchone()["status"] == "FAILED"
    assert client.get(f"{API}/invoices/{inv['id']}", headers=m["h"]).json()["status"] == "PENDING"


def test_wrong_network_refused(setup, client, chain):
    m, inv = setup
    t = pay(chain, inv)
    chain.cid = 2625  # legacy testnet
    r = verify(client, m["h"], t)
    assert r.status_code == 502 and r.json()["error"]["code"] == "wrong_network"
    assert client.get(f"{API}/invoices/{inv['id']}", headers=m["h"]).json()["status"] == "PENDING"


def test_wrong_usdt_token_rejected(setup, client, chain):
    m, inv = setup
    # event is genuine but the money moved in a different token
    t = pay(chain, inv, token=OTHER_TOKEN)
    b = verify(client, m["h"], t).json()
    assert b["stage"] == "rejected" and "USDT" in b["detail"]
    assert client.get(f"{API}/invoices/{inv['id']}", headers=m["h"]).json()["status"] == "PENDING"


def test_transfer_amount_must_match_event(setup, client, chain):
    m, inv = setup
    logs = [erc20_transfer(PAYER, MERCHANT_WALLET, 1, address=USDT, tx_hash=tx(6), log_index=0),
            invoice_paid(inv, PAYER, MERCHANT_WALLET, 100_000_000, 100_000_000, tx_hash=tx(6), log_index=1)]
    chain.add(tx(6), logs)
    assert verify(client, m["h"], tx(6)).json()["stage"] == "rejected"


def test_event_from_unconfigured_contract_ignored(setup, client, chain):
    m, inv = setup
    t = pay(chain, inv, contract="0x" + "77" * 20)  # attacker's lookalike contract
    b = verify(client, m["h"], t).json()
    assert b["stage"] == "rejected" and "no BillFlow contract events" in b["detail"]
    assert client.get(f"{API}/invoices/{inv['id']}", headers=m["h"]).json()["status"] == "PENDING"


@pytest.mark.parametrize("tamper,reason", [
    ({"onchain_invoice_id": h32("unknown-invoice")}, "unknown_invoice"),
    ({"invoice_hash": h32("other-hash")}, "invoice_hash_mismatch"),
    ({"amount_base": "999"}, "invoice_total_mismatch"),
])
def test_wrong_invoice_reference_rejected(setup, client, chain, tamper, reason):
    m, inv = setup
    t = pay(chain, inv, **tamper)
    b = verify(client, m["h"], t).json()
    assert b["stage"] == "rejected" and reason in b["detail"], b
    assert client.get(f"{API}/invoices/{inv['id']}", headers=m["h"]).json()["status"] == "PENDING"


def test_payment_to_other_merchant_wallet_rejected(setup, client, chain):
    m, inv = setup
    other = "0x" + "dd" * 20
    t = pay(chain, inv, merchant=other)
    b = verify(client, m["h"], t).json()
    assert b["stage"] == "rejected" and "merchant_mismatch" in b["detail"]


def test_overpayment_rejected(setup, client, chain):
    m, inv = setup
    b = verify(client, m["h"], pay(chain, inv, amount=100_000_000, total=150_000_000)).json()
    assert b["stage"] == "rejected" and "amount_inconsistent" in b["detail"]


def test_bad_hash_format(setup, client):
    m, _ = setup
    for bad in ("0x123", "zz" * 32, "", "0x" + "g" * 64):
        assert verify(client, m["h"], bad).status_code == 422


def test_payment_visibility(setup, client, chain, w):
    m, inv = setup
    t = pay(chain, inv)
    verify(client, m["h"], t)
    pid = client.get(f"{API}/payments/transaction/{t}", headers=m["h"]).json()[0]["id"]
    other = w.merchant("0x" + "bb" * 20)
    assert client.get(f"{API}/payments/{pid}", headers=other["h"]).status_code == 404
    assert client.get(f"{API}/payments/transaction/{t}", headers=other["h"]).status_code == 404
    assert client.get(f"{API}/payments", headers=other["h"]).json()["total"] == 0
    payer_user = w.user("customer"); w.set_wallet(payer_user, PAYER)
    assert client.get(f"{API}/payments/{pid}", headers=payer_user["h"]).status_code == 200  # the payer can see own payment
    assert client.get(f"{API}/payments", headers=m["h"]).json()["total"] == 1
    assert client.get(f"{API}/payments/invoice/{inv['id']}", headers=other["h"]).status_code == 404  # not their invoice
    adm = w.user("admin")
    assert client.get(f"{API}/payments/{pid}", headers=adm["h"]).status_code == 200


def test_unrelated_user_gets_redacted_verify_result(setup, client, chain, w):
    m, inv = setup
    t = pay(chain, inv)
    stranger = w.user("customer")
    b = verify(client, stranger["h"], t).json()
    assert b["events"] == [] and b["payment_ids"] == []


# ───────────── quotes (public payment intent) ─────────────
def _link(client, m, inv):
    return client.post(f"{API}/invoices/{inv['id']}/payment-link", headers=m["h"]).json()["token"]


def test_payment_intent_signature_recovers_to_signer(setup, client):
    m, inv = setup
    tok = _link(client, m, inv)
    r = client.post(f"{API}/public/invoices/{tok}/payment-intent", json={"payer_wallet": PAYER})
    assert r.status_code == 200, r.text
    b = r.json()
    q = {**b["quote"], "amount": int(b["quote"]["amount"]), "invoiceTotal": int(b["quote"]["invoiceTotal"]),
         "nonce": int(b["quote"]["nonce"]), "expiry": int(b["quote"]["expiry"])}
    types = {"EIP712Domain": [{"name": "name", "type": "string"}, {"name": "version", "type": "string"}, {"name": "chainId", "type": "uint256"},
                              {"name": "verifyingContract", "type": "address"}],
             "Quote": [{"name": "invoiceId", "type": "bytes32"}, {"name": "invoiceHash", "type": "bytes32"}, {"name": "merchant", "type": "address"},
                       {"name": "payer", "type": "address"}, {"name": "amount", "type": "uint256"}, {"name": "invoiceTotal", "type": "uint256"},
                       {"name": "nonce", "type": "uint256"}, {"name": "expiry", "type": "uint64"}]}
    msg = encode_typed_data(full_message={"types": types, "primaryType": "Quote", "domain": b["eip712_domain"], "message": q})
    assert Account.recover_message(msg, signature=b["signature"]).lower() == Account.from_key(SIGNER_KEY).address.lower()
    assert b["chain_id"] == CHAIN_ID and b["payments_contract"].lower() == PAYMENTS and b["approve_amount_base"] == "100000000"
    assert q["merchant"].lower() == MERCHANT_WALLET and q["payer"].lower() == PAYER and q["invoiceHash"] == inv["invoice_hash"]
    # nonces are unique
    b2 = client.post(f"{API}/public/invoices/{tok}/payment-intent", json={"payer_wallet": PAYER}).json()
    assert b2["quote"]["nonce"] != b["quote"]["nonce"]


def test_payment_intent_rules(setup, client, chain, w):
    m, inv = setup
    tok = _link(client, m, inv)
    url = f"{API}/public/invoices/{tok}/payment-intent"
    assert client.post(url, json={"payer_wallet": "nope"}).status_code == 400
    assert client.post(url, json={"payer_wallet": PAYER, "amount": "100.01"}).status_code == 400  # > remaining
    assert client.post(url, json={"payer_wallet": PAYER, "amount": "0"}).status_code == 400
    ok = client.post(url, json={"payer_wallet": PAYER, "amount": "25.5"})
    assert ok.status_code == 200 and ok.json()["approve_amount_base"] == "25500000"
    verify(client, m["h"], pay(chain, inv, 1, 100_000_000))
    gone = client.post(url, json={"payer_wallet": PAYER})  # now PAID
    assert gone.status_code == 409 and gone.json()["error"]["code"] == "invoice_not_payable"


def test_no_quote_for_financed_invoice(setup, client, w, conn):
    m, inv = setup
    tok = _link(client, m, inv)
    conn.execute("""insert into financing_offers (invoice_id, business_id, face_value_base, advance_base, maturity_date, funding_deadline, debtor_name)
                    select id, business_id, amount_base, amount_base - 1, due_date, now() + interval '1 day', 'x' from invoices where id=%s""", (inv["id"],))
    r = client.post(f"{API}/public/invoices/{tok}/payment-intent", json={"payer_wallet": PAYER})
    assert r.status_code == 409 and "financing" in r.json()["error"]["message"]
    assert client.get(f"{API}/public/invoices/{tok}/status").json()["payable"] is False


def test_quote_requires_signer_configured(setup, client, monkeypatch):
    from app.core.config import get_settings
    m, inv = setup
    tok = _link(client, m, inv)
    monkeypatch.setenv("QUOTE_SIGNER_PRIVATE_KEY", ""); get_settings.cache_clear()
    try:
        r = client.post(f"{API}/public/invoices/{tok}/payment-intent", json={"payer_wallet": PAYER})
        assert r.status_code == 503 and r.json()["error"]["code"] == "payments_not_configured"
    finally:
        monkeypatch.setenv("QUOTE_SIGNER_PRIVATE_KEY", SIGNER_KEY); get_settings.cache_clear()
