"""Dev helper (not a test): python -m pytest tests/gen_examples.py -s  -> /tmp/examples.json. Uses the MOCK chain/AI."""
import json
from datetime import date, timedelta

from eth_account import Account
from tests.helpers import erc20_transfer, h32, invoice_paid, pdf_bytes
from tests.test_financing import ACK, NOTICE, Chain, approve

API = "/api/v1"
OUT = {}


def rec(name, r):
    try:
        body = r.json()
    except Exception:
        body = None
    OUT[name] = {"status": r.status_code, "body": body}
    return r


def test_gen(w, client, chain, llm):
    m = w.merchant("0x" + "aa" * 20); c = w.customer(m, "Globex Corp", wallet="0x" + "99" * 20)
    r = rec("create_invoice", client.post(f"{API}/invoices", json={"customer_id": c["id"], "invoice_number": "INV-2026-001", "description": "Consulting, October",
            "amount": "100", "due_date": str(date.today() + timedelta(days=30)), "issue": True}, headers=m["h"]))
    inv = r.json()
    rec("upload", client.post(f"{API}/invoices/{inv['id']}/upload", files={"file": ("inv.pdf", pdf_bytes(), "application/pdf")}, headers=m["h"]))
    link = rec("payment_link", client.post(f"{API}/invoices/{inv['id']}/payment-link", headers=m["h"])).json()
    rec("public_view", client.get(f"{API}/public/invoices/{link['token']}"))
    rec("payment_intent", client.post(f"{API}/public/invoices/{link['token']}/payment-intent", json={"payer_wallet": "0x" + "99" * 20}))
    t = h32("example-pay")
    chain.add(t, [erc20_transfer("0x" + "99" * 20, "0x" + "aa" * 20, 100_000_000, tx_hash=t, log_index=0),
                  invoice_paid(inv, "0x" + "99" * 20, "0x" + "aa" * 20, 100_000_000, 100_000_000, tx_hash=t, log_index=1)])
    rec("verify_payment", client.post(f"{API}/payments/verify", json={"tx_hash": t}, headers=m["h"]))
    rec("payment_status", client.get(f"{API}/invoices/{inv['id']}/payment-status", headers=m["h"]))
    rec("verify_unknown_tx", client.post(f"{API}/payments/verify", json={"tx_hash": h32("nothing")}, headers=m["h"]))
    rec("error_forbidden", client.get(f"{API}/admin/users", headers=m["h"]))
    # financing
    c2 = w.customer(m, "Initech", wallet="0x" + "98" * 20)
    inv2 = w.invoice(m, c2, number="INV-2026-002", amount="100")
    adm = w.user("admin")
    e = {"m": m, "inv": inv2, "adm": adm}
    rec("financing_submit", client.post(f"{API}/financing/submit", json={"invoice_id": inv2["id"], "advance": "90"}, headers=m["h"]))
    o = client.get(f"{API}/financing/offers", headers=adm["h"]).json()["items"][0]
    rec("financing_approve", approve(client, e, o["id"]))
    client.post(f"{API}/invoices/{inv2['id']}/upload", files={"file": ("i2.pdf", pdf_bytes(), "application/pdf")}, headers=m["h"])
    rec("financing_publish", client.post(f"{API}/financing/offers/{o['id']}/publish", headers=adm["h"]))
    ch = Chain(chain, client, e, o)
    rec("financing_verify_tx", ch.verify(ch.registered()))
    llm.response = {"invoice_number": "INV-2026-003", "merchant_name": "Acme Ltd", "customer_name": "Globex Corp", "amount": "1250.50", "currency": "USDT",
                    "issue_date": "2026-10-01", "due_date": "2026-11-01", "confidence": 0.93, "field_confidence": {"amount": 0.99}, "warnings": []}
    rec("ai_extract", client.post(f"{API}/ai/extract-invoice", files={"file": ("x.pdf", pdf_bytes(), "application/pdf")}, headers=m["h"]))
    llm.response = {"foo": "bar"}
    rec("ai_invalid_output", client.post(f"{API}/ai/extract-invoice", files={"file": ("x.pdf", pdf_bytes(), "application/pdf")}, headers=m["h"]))
    json.dump(OUT, open("/tmp/examples.json", "w"), indent=2, default=str)
