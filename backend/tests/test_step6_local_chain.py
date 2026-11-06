"""LOCAL-CHAIN end-to-end for Step 6, with REAL compiled contracts on Anvil (chain id 1874) and the REAL stack end to end:

  demo merchant (Node) --API key--> BillFlow API (uvicorn) <--billflow.js pay() (Node, wallet shim -> Anvil)
  BillFlow -> signed webhook -> demo merchant ;  merchant wallet -> BillFlowRefunds (real contract) -> backend verification

!! NOT a Whitechain test. The token is a local MockERC20 and keys are the public Anvil mnemonic. It proves the pieces work together;
   it proves nothing about the live testnet or the official USDT. !!
"""
from __future__ import annotations

import csv
import io
import json
import os
import shutil
import socket
import subprocess
import threading
import time
from pathlib import Path

import httpx
import pytest
from web3 import Web3

from tests.test_local_chain_e2e import ANVIL, OUT, PORT, API, local  # noqa: F401  (re-used module-scoped fixture)

NODE = shutil.which("node")
ROOT = Path(__file__).resolve().parents[2]
pytestmark = pytest.mark.skipif(NODE is None or ANVIL is None or not (OUT / "BillFlowRefunds.sol").exists(),
                                reason="needs node, anvil and `forge build` artifacts")


def free_port() -> int:
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p


def wait_http(url: str, tries: int = 60) -> None:
    for _ in range(tries):
        try:
            httpx.get(url, timeout=1)
            return
        except Exception:
            time.sleep(0.2)
    raise AssertionError(f"{url} did not come up")


@pytest.fixture()
def stack(local, db, storage, llm, authc, monkeypatch):  # noqa: F811
    import uvicorn
    import psycopg
    from app.core.config import get_settings
    from app.main import create_app
    from tests.conftest import World

    L = local
    s = get_settings()
    L.refunds = L.deploy("BillFlowRefunds.sol/BillFlowRefunds.json", L.pay.address, L.admin.address, L.admin.address)
    api_port = free_port()
    monkeypatch.setattr(s, "whitechain_refunds_contract", L.refunds.address.lower())
    monkeypatch.setattr(s, "public_checkout_base_url", f"http://127.0.0.1:{api_port}")
    monkeypatch.setattr(s, "webhook_allow_insecure_urls", True)

    server = uvicorn.Server(uvicorn.Config(create_app(), host="127.0.0.1", port=api_port, log_level="warning"))
    t = threading.Thread(target=server.run, daemon=True); t.start()
    wait_http(f"http://127.0.0.1:{api_port}/health")
    base = f"http://127.0.0.1:{api_port}"
    http = httpx.Client(base_url=base, timeout=30)
    procs = []
    with psycopg.connect(db, autocommit=True, row_factory=psycopg.rows.dict_row) as c:
        yield {"L": L, "s": s, "base": base, "http": http, "w": World(c, http), "c": c, "procs": procs}
    for p in procs:
        p.terminate()
    server.should_exit = True
    t.join(timeout=10)


def start_demo(stack, api_key: str, secret: str, port: int) -> str:
    env = {**os.environ, "BILLFLOW_URL": stack["base"], "BILLFLOW_API_KEY": api_key, "BILLFLOW_WEBHOOK_SECRET": secret,
           "PORT": str(port), "PUBLIC_URL": f"http://127.0.0.1:{port}", "PRICE": "40.00"}
    p = subprocess.Popen([NODE, "server.js"], cwd=ROOT / "demo-merchant", env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    stack["procs"].append(p)
    wait_http(f"http://127.0.0.1:{port}/api/orders")
    return f"http://127.0.0.1:{port}"


def run_widget(checkout_url: str, payer: str) -> dict:
    r = subprocess.run([NODE, "tests/js/e2e_driver.js"], cwd=ROOT / "backend", capture_output=True, text=True, timeout=120,
                       env={**os.environ, "CHECKOUT_URL": checkout_url, "ANVIL_RPC": f"http://127.0.0.1:{PORT}", "PAYER": payer})
    assert r.stdout.strip(), r.stderr
    return json.loads(r.stdout.strip().splitlines()[-1])


def test_checkout_widget_refunds_webhooks_csv_end_to_end(stack):
    L, s, http, w, db = stack["L"], stack["s"], stack["http"], stack["w"], stack["c"]
    from app.services import webhook_service as wh

    # merchant account, API key, webhook endpoint (secret shown once) --------------------------------------------------------------
    m = w.merchant(L.merchant.address.lower())
    key = http.post(f"{API}/merchant/api-keys", json={"name": "demo store"}, headers=m["h"]).json()["key"]
    demo_port = free_port()
    hook = http.post(f"{API}/merchant/webhooks", json={"url": f"http://127.0.0.1:{demo_port}/webhooks/billflow"}, headers=m["h"]).json()
    demo = start_demo(stack, key, hook["secret"], demo_port)
    L.send(L.admin, L.usdt.functions.mint(L.payer.address, 500 * 10**6))  # local mock token only

    # 1) independent demo store creates the checkout session server-side with its API key ------------------------------------------
    created = httpx.post(f"{demo}/api/checkout", timeout=30).json()
    url, order_id = created["checkout_url"], created["order_id"]
    assert url.startswith(stack["base"] + "/pay/")
    assert httpx.get(url).status_code == 200  # hosted checkout page is served
    assert httpx.get(f"{demo}/api/orders").json()[0]["status"] == "awaiting_payment"

    # 2) the REAL billflow.js pay() flow: approve + payInvoice, then backend verification ------------------------------------------
    payer_before, merchant_before = (L.usdt.functions.balanceOf(a).call() for a in (L.payer.address, L.merchant.address))
    res = run_widget(url, L.payer.address)
    assert res["ok"], res
    assert res["steps"][-1] == "done" and "approve" in res["steps"] and "verifying" in res["steps"]
    rc = res["receipt"]
    assert rc["amount"] == "40" and rc["currency"] == "USDT" and rc["chain_id"] == 1874
    assert rc["payer_wallet"] == L.payer.address.lower() and rc["explorer_url"].endswith(rc["tx_hash"])
    assert L.usdt.functions.balanceOf(L.merchant.address).call() - merchant_before == 40 * 10**6  # real token movement on the local chain
    assert payer_before - L.usdt.functions.balanceOf(L.payer.address).call() == 40 * 10**6
    row = db.execute("select * from payments").fetchone()
    assert row["status"] == "CONFIRMED" and row["onchain_payment_id"] == 1
    sess = httpx.get(f"{stack['base']}{API}/checkout/sessions/{created['order_id'] and db.execute('select id from checkout_sessions').fetchone()['id']}",
                     headers={"Authorization": f"Bearer {key}"}).json()
    assert sess["status"] == "paid" and sess["reference"] == order_id and sess["receipts"][0]["tx_hash"] == rc["tx_hash"]

    # a second attempt on the paid link is refused by the widget flow (not payable) and by the contract
    again = run_widget(url, L.payer.address)
    assert again["ok"] is False and again["code"] in ("not_payable", "link_expired"), again

    # 3) signed webhooks reach the independent merchant app; the order flips only because of a verified signature -------------------
    assert wh.deliver_due(s)["sent"] == 2  # payment.confirmed + invoice.paid
    order = httpx.get(f"{demo}/api/orders").json()[0]
    assert order["status"] == "paid" and order["tx"] == rc["tx_hash"]
    assert wh.deliver_due(s) == {"sent": 0, "failed": 0, "gave_up": 0}
    forged = httpx.post(f"{demo}/webhooks/billflow", content=json.dumps({"id": "x", "type": "invoice.paid", "data": {"reference": order_id}}),
                        headers={"BillFlow-Signature": "t=1,v1=00"})
    assert forged.status_code == 400

    # 4) refunds through the REAL BillFlowRefunds contract ------------------------------------------------------------------------
    pid = str(row["id"])
    prep = http.post(f"{API}/merchant/payments/{pid}/refunds", json={"amount": "15", "reason": "late delivery"}, headers=m["h"]).json()
    approve, refund = prep["plan"]["steps"]
    assert refund["args"]["paymentId"] == "1"
    ra = lambda: L.refunds.functions.refund(1, 15 * 10**6, prep["refund_ref"], prep["reason_hash"])  # noqa: E731

    assert L.send(L.payer, ra(), expect_revert=True) is None, "only the recorded merchant may refund"
    assert L.send(L.merchant, ra(), expect_revert=True) is None, "no allowance yet -> reverts"
    L.send(L.merchant, L.usdt.functions.approve(L.refunds.address, 40 * 10**6))
    r1 = L.send(L.merchant, ra())
    assert L.send(L.merchant, ra(), expect_revert=True) is None, "same refundRef cannot be replayed"
    assert L.send(L.merchant, L.refunds.functions.refund(1, 26 * 10**6, "0x" + "09" * 32, "0x" + "00" * 32), expect_revert=True) is None, "cannot exceed payment"
    L.mine(4)
    t1 = "0x" + r1.transactionHash.hex().removeprefix("0x")
    payer_mid = L.usdt.functions.balanceOf(L.payer.address).call()
    v = http.post(f"{API}/merchant/refunds/verify", json={"tx_hash": t1}, headers=m["h"]).json()
    assert v["stage"] == "verified" and v["refunds"][0]["status"] == "CONFIRMED" and v["refunds"][0]["amount"] == "15", v
    assert db.execute("select refunded_amount_base from payments").fetchone()["refunded_amount_base"] == 15 * 10**6
    chk = http.get(f"{API}/merchant/refunds/{prep['id']}/chain-check", headers=m["h"]).json()
    assert chk["checked"] and chk["matches_chain"] and chk["onchain_total_refunded_base"] == str(15 * 10**6)
    assert payer_mid - payer_before + 40 * 10**6 == 15 * 10**6  # payer got exactly 15 back

    # final refund of the remainder, executed by a merchant-side app, status verified independently
    prep2 = http.post(f"{API}/merchant/payments/{pid}/refunds", json={"amount_base": str(25 * 10**6)}, headers=m["h"]).json()
    r2 = L.send(L.merchant, L.refunds.functions.refund(1, 25 * 10**6, prep2["refund_ref"], prep2["reason_hash"]))
    L.mine(4)
    assert http.post(f"{API}/merchant/refunds/verify", json={"tx_hash": "0x" + r2.transactionHash.hex().removeprefix("0x")}, headers=m["h"]).json()["stage"] == "verified"
    assert L.usdt.functions.balanceOf(L.payer.address).call() == payer_before, "payer fully made whole"
    assert http.post(f"{API}/merchant/payments/{pid}/refunds", json={"amount": "0.000001"}, headers=m["h"]).status_code == 400
    assert L.send(L.merchant, L.refunds.functions.refund(1, 1, "0x" + "0a" * 32, "0x" + "00" * 32), expect_revert=True) is None
    assert L.usdt.functions.balanceOf(L.refunds.address).call() == 0

    assert wh.deliver_due(s)["sent"] == 2  # two refund.confirmed
    order = httpx.get(f"{demo}/api/orders").json()[0]
    assert order["status"] == "refunded" and order["refunded"] == "40.000000"

    # 5) accountant CSV ------------------------------------------------------------------------------------------------------------
    rows = list(csv.DictReader(io.StringIO(http.get(f"{API}/merchant/exports/payments.csv", headers=m["h"]).text)))
    assert [r["type"] for r in rows] == ["payment", "refund", "refund"]
    assert [r["amount"] for r in rows] == ["40", "-15", "-25"] and rows[0]["reference"] == order_id
    assert sum(int(r["amount_base"]) for r in rows) == 0

    # 6) preflight recognises the refunds deployment ---------------------------------------------------------------------------------
    from app.services.blockchain_service import get_blockchain
    from app.services.payment_service import signer_address
    pf = get_blockchain(s).preflight(signer_address(s))
    assert pf["refunds_has_code"]["ok"] and pf["refunds_token_matches"]["ok"] and pf["refunds_points_at_payments"]["ok"], pf


def test_widget_refuses_cancelled_session_without_sending_any_transaction(stack):
    """An expired/cancelled session must stop the widget before the wallet is asked to sign anything (merchant balance stays 0)."""
    L, http, w = stack["L"], stack["http"], stack["w"]
    m = w.merchant(L.merchant.address.lower())
    key = http.post(f"{API}/merchant/api-keys", json={"name": "k"}, headers=m["h"]).json()["key"]
    sess = http.post(f"{API}/checkout/sessions", json={"amount": "5", "reference": "t"}, headers={"Authorization": f"Bearer {key}"}).json()
    http.post(f"{API}/checkout/sessions/{sess['id']}/expire", headers={"Authorization": f"Bearer {key}"})
    res = run_widget(sess["checkout_url"], L.payer.address)
    assert res["ok"] is False and res["code"] in ("link_expired", "not_payable")
    assert "approve" not in res["steps"] and "pay" not in res["steps"]
    assert L.usdt.functions.balanceOf(L.merchant.address).call() == 0
