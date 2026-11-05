"""LOCAL-CHAIN end-to-end test: the REAL compiled contracts on a local Anvil node (chain id 1874), driven through the REAL FastAPI app
and the REAL web3 chain client / event decoder / verifier. Only Supabase Storage/Auth and Claude are faked.

!! This is NOT a Whitechain test. It uses a locally deployed MockERC20 (6 decimals) as "USDT" and throw-away keys derived from the
   public Anvil mnemonic. It proves contract <-> backend compatibility; it does not prove anything about the live testnet. !!

Skipped automatically unless `anvil` and compiled artifacts (contracts/out, run `forge build`) are available.
"""
from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import time
from pathlib import Path

import pytest
from eth_account import Account
from web3 import Web3

from tests.helpers import pdf_bytes

Account.enable_unaudited_hdwallet_features()
ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "contracts" / "out"
ANVIL = shutil.which("anvil") or ("/opt/foundry/anvil" if Path("/opt/foundry/anvil").exists() else None)
MNEMONIC = "test test test test test test test test test test test junk"  # public Anvil default; worthless
API = "/api/v1"
PORT = 8546

pytestmark = pytest.mark.skipif(
    ANVIL is None or not (OUT / "BillFlowPayments.sol" / "BillFlowPayments.json").exists(),
    reason="needs anvil and `forge build` artifacts (contracts/out)",
)


def acct(i: int):
    return Account.from_mnemonic(MNEMONIC, account_path=f"m/44'/60'/0'/0/{i}")


def artifact(rel: str) -> dict:
    return json.loads((OUT / rel).read_text())


class Local:
    def __init__(self):
        self.w3 = Web3(Web3.HTTPProvider(f"http://127.0.0.1:{PORT}"))
        self.admin, self.merchant, self.payer, self.investor, self.signer = (acct(i) for i in range(5))

    def deploy(self, rel: str, *args):
        a = artifact(rel)
        c = self.w3.eth.contract(abi=a["abi"], bytecode=a["bytecode"]["object"])
        r = self.send(self.admin, c.constructor(*args))
        return self.w3.eth.contract(address=r.contractAddress, abi=a["abi"])

    def send(self, who, fn, *, expect_revert: bool = False):
        """Sign locally with a throw-away key and broadcast. expect_revert=True returns None if the call would revert."""
        try:
            tx = fn.build_transaction({"from": who.address, "nonce": self.w3.eth.get_transaction_count(who.address),
                                       "chainId": 1874, "gasPrice": self.w3.eth.gas_price})
        except Exception:
            if expect_revert:
                return None
            raise
        signed = who.sign_transaction(tx)
        h = self.w3.eth.send_raw_transaction(signed.raw_transaction)
        r = self.w3.eth.wait_for_transaction_receipt(h)
        assert r.status == 1, "transaction reverted on-chain"
        return r

    def mine(self, n: int = 4):
        self.w3.provider.make_request("anvil_mine", [hex(n)])


@pytest.fixture(scope="module")
def local():
    s = socket.socket()
    if s.connect_ex(("127.0.0.1", PORT)) == 0:
        pytest.skip(f"port {PORT} busy")
    s.close()
    proc = subprocess.Popen([ANVIL, "--chain-id", "1874", "--port", str(PORT), "--mnemonic", MNEMONIC, "--silent"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    L = Local()
    try:
        for _ in range(50):
            try:
                if L.w3.is_connected():
                    break
            except Exception:
                pass
            time.sleep(0.2)
        assert L.w3.eth.chain_id == 1874
        L.usdt = L.deploy("Mocks.sol/MockERC20.json", 6)
        L.pay = L.deploy("BillFlowPayments.sol/BillFlowPayments.json", L.usdt.address, L.admin.address, L.signer.address, L.admin.address)
        L.fin = L.deploy("InvoiceFinancing.sol/InvoiceFinancing.json", L.usdt.address, L.admin.address)
        for role in ("ISSUER_ROLE", "VERIFIER_ROLE", "OPERATOR_ROLE"):
            L.send(L.admin, L.fin.functions.grantRole(getattr(L.fin.functions, role)().call(), L.admin.address))
        L.send(L.admin, L.fin.functions.setBusinessApproved(L.merchant.address, True))
        L.send(L.admin, L.fin.functions.setInvestorApproved(L.investor.address, True))
        L.usdt.fn = L.usdt.functions
        env = {"WHITECHAIN_RPC_URL": f"http://127.0.0.1:{PORT}", "WHITECHAIN_CHAIN_ID": "1874",
               "WHITECHAIN_USDT_ADDRESS": L.usdt.address.lower(), "USDT_DECIMALS": "6",
               "WHITECHAIN_PAYMENT_CONTRACT": L.pay.address.lower(), "WHITECHAIN_FINANCING_CONTRACT": L.fin.address.lower(),
               "QUOTE_SIGNER_PRIVATE_KEY": L.signer.key.hex() if L.signer.key.hex().startswith("0x") else "0x" + L.signer.key.hex(),
               "MIN_CONFIRMATIONS": "3"}
        saved = {k: os.environ.get(k) for k in env}
        os.environ.update(env)
        from app.core.config import get_settings
        from app.services import blockchain_service as bs
        get_settings.cache_clear()
        bs._default_client.cache_clear()
        bs.set_chain_client(None)
        yield L
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        get_settings.cache_clear()
        bs._default_client.cache_clear()
    finally:
        proc.terminate()


@pytest.fixture()
def live(local, db, storage, llm, authc):
    from fastapi.testclient import TestClient
    from app.main import create_app
    from tests.conftest import World
    import psycopg
    with psycopg.connect(db, autocommit=True, row_factory=psycopg.rows.dict_row) as c, TestClient(create_app()) as tc:
        yield local, World(c, tc), tc, c


def test_dart_payinvoice_vector_matches_web3_encoding(local):
    """The Flutter test vector (computed independently in Python) equals what web3 encodes from the compiled ABI."""
    quote = ("0x" + "01" * 32, "0x" + "02" * 32, Web3.to_checksum_address("0x" + "aa" * 20), Web3.to_checksum_address("0x" + "bb" * 20), 100000000, 100000000, 12345, 1893456000)
    sig = bytes(range(65))
    data = local.pay.encode_abi("payInvoice", args=[quote, sig])
    expected = ("0xa87ce778" + "01" * 32 + "02" * 32 + "00" * 12 + "aa" * 20 + "00" * 12 + "bb" * 20
                + f"{100000000:064x}" * 2 + f"{12345:064x}" + f"{1893456000:064x}" + f"{0x120:064x}" + f"{65:064x}" + sig.hex().ljust(192, "0"))
    assert data.lower() == expected


def test_payment_flow_real_contract_and_backend_verification(live):
    L, w, c, db = live
    m = w.merchant(L.merchant.address.lower())
    cust = w.customer(m, wallet=L.payer.address.lower())
    inv = w.invoice(m, cust, number="INV-E2E-1", amount="1000")
    link = c.post(f"{API}/invoices/{inv['id']}/payment-link", headers=m["h"]).json()
    token = link["token"]

    pub = c.get(f"{API}/public/invoices/{token}").json()
    assert pub["chain_id"] == 1874 and pub["usdt_address"].lower() == L.usdt.address.lower()
    assert pub["payments_contract"].lower() == L.pay.address.lower() and pub["amount"] == "1000"
    assert set(pub) .isdisjoint({"merchant_id", "customer_id", "payout_wallet", "customer_name"}), "public payload leaks internal fields"

    L.send(L.admin, L.usdt.functions.mint(L.payer.address, 5000 * 10**6))  # local mock token only
    merchant_before = L.usdt.functions.balanceOf(L.merchant.address).call()

    intent = c.post(f"{API}/public/invoices/{token}/payment-intent", json={"payer_wallet": L.payer.address.lower()}).json()
    q = intent["quote"]
    assert q["amount"] == str(1000 * 10**6) and q["merchant"].lower() == L.merchant.address.lower()
    L.send(L.payer, L.usdt.functions.approve(L.pay.address, int(intent["approve_amount_base"])))
    quote_tuple = (q["invoiceId"], q["invoiceHash"], Web3.to_checksum_address(q["merchant"]), Web3.to_checksum_address(q["payer"]),
                   int(q["amount"]), int(q["invoiceTotal"]), int(q["nonce"]), int(q["expiry"]))
    sig = bytes.fromhex(intent["signature"][2:])

    # wrong caller cannot use someone else's quote
    assert L.send(L.investor, L.pay.functions.payInvoice(quote_tuple, sig), expect_revert=True) is None

    r = L.send(L.payer, L.pay.functions.payInvoice(quote_tuple, sig))
    tx_hash = "0x" + r.transactionHash.hex().removeprefix("0x")

    # before enough confirmations the backend must NOT mark it paid
    early = c.post(f"{API}/payments/verify", json={"tx_hash": tx_hash}, headers=m["h"]).json()
    assert early["stage"] in ("submitted", "verified")  # anvil mines 1 block per tx; min confirmations is 3
    if early["stage"] != "verified":
        assert w.invoice_row(inv["id"])["status"] == "PENDING"
    L.mine(4)
    ok = c.post(f"{API}/payments/verify", json={"tx_hash": tx_hash}, headers=m["h"])
    assert ok.status_code == 200, ok.text
    assert ok.json()["stage"] == "verified", ok.json()
    row = w.invoice_row(inv["id"])
    assert row["status"] == "PAID" and row["paid_amount_base"] == 1000 * 10**6
    assert L.usdt.functions.balanceOf(L.merchant.address).call() - merchant_before == 1000 * 10**6  # real USDT reached the merchant
    st = c.get(f"{API}/public/invoices/{token}/status").json()
    assert st["status"] == "PAID" and st["payments"][0]["tx_hash"].lower() == tx_hash.lower()

    # idempotent re-verification, and the contract itself refuses a duplicate payment
    again = c.post(f"{API}/payments/verify", json={"tx_hash": tx_hash}, headers=m["h"])
    assert again.status_code == 200
    assert db.execute("select count(*) n from payments where invoice_id=%s", (inv["id"],)).fetchone()["n"] == 1
    assert L.send(L.payer, L.pay.functions.payInvoice(quote_tuple, sig), expect_revert=True) is None


def test_financing_lifecycle_real_contract_and_backend_verification(live):
    L, w, c, db = live
    m = w.merchant(L.merchant.address.lower())
    cust = w.customer(m, wallet=L.payer.address.lower())
    inv = w.invoice(m, cust, number="INV-E2E-FIN", amount="1000", days=30)
    adm = w.user("admin")
    investor = w.user("investor"); w.set_wallet(investor, L.investor.address.lower())
    c.post(f"{API}/invoices/{inv['id']}/upload", files={"file": ("i.pdf", pdf_bytes(), "application/pdf")}, headers=m["h"])

    o = c.post(f"{API}/financing/submit", json={"invoice_id": inv["id"], "advance": "900"}, headers=m["h"]).json()
    assert o["status"] == "REQUESTED"
    # duplicate financing request is rejected
    assert c.post(f"{API}/financing/submit", json={"invoice_id": inv["id"], "advance": "900"}, headers=m["h"]).status_code in (409, 422)
    appr = c.post(f"{API}/financing/offers/{o['id']}/verify", headers=adm["h"], json={
        "decision": "approve", "debtor_ack": {"evidence_ref": "email-thread-42", "acknowledged_at": "2026-11-01T10:00:00Z", "acknowledged_by": "CFO"},
        "assignment_notice": {"reference": "assignment-letter-7"}})
    assert appr.status_code == 200, appr.text

    def run_next_step():
        plan = c.post(f"{API}/financing/offers/{o['id']}/publish", headers=adm["h"]).json()
        step = plan["next_step"]; a = step["args"]
        if step["function"] == "registerInvoice":
            p = a["p"]
            fn = L.fin.functions.registerInvoice((p["invoiceHash"], p["documentHash"], p["debtorRef"], Web3.to_checksum_address(p["business"]),
                                                  Web3.to_checksum_address(p["debtor"]), int(p["faceValue"]), int(p["issueDate"]), int(p["dueDate"])))
        elif step["function"] == "verifyInvoice":
            fn = L.fin.functions.verifyInvoice(int(a["invoiceId"]), a["debtorAckRef"])
        else:
            fn = L.fin.functions.createOffer(int(a["invoiceId"]), int(a["advance"]), int(a["fundingDeadline"]))
        r = L.send(L.admin, fn)
        L.mine(4)
        v = c.post(f"{API}/financing/verify-transaction", json={"tx_hash": "0x" + r.transactionHash.hex().removeprefix("0x")}, headers=adm["h"])
        assert v.status_code == 200 and v.json()["stage"] == "verified", v.text
        return step["function"]

    assert [run_next_step() for _ in range(3)] == ["registerInvoice", "verifyInvoice", "createOffer"]
    off = c.get(f"{API}/financing/offers/{o['id']}", headers=investor["h"]).json()
    assert off["status"] == "LISTED" and off["onchain_offer_id"]
    onchain_id = int(off["onchain_offer_id"])

    # investor funds with real (mock) USDT; business must receive the advance directly
    L.send(L.admin, L.usdt.functions.mint(L.investor.address, 2000 * 10**6))
    biz_before = L.usdt.functions.balanceOf(L.merchant.address).call()
    L.send(L.investor, L.usdt.functions.approve(L.fin.address, 900 * 10**6))
    # insufficient allowance / wrong role are refused by the contract
    assert L.send(L.payer, L.fin.functions.fund(onchain_id), expect_revert=True) is None
    r = L.send(L.investor, L.fin.functions.fund(onchain_id))
    L.mine(4)
    v = c.post(f"{API}/financing/verify-transaction", json={"tx_hash": "0x" + r.transactionHash.hex().removeprefix("0x")}, headers=investor["h"])
    assert v.status_code == 200 and v.json()["stage"] == "verified", v.text
    assert L.usdt.functions.balanceOf(L.merchant.address).call() - biz_before == 900 * 10**6
    assert c.get(f"{API}/financing/offers/{o['id']}", headers=investor["h"]).json()["status"] == "FUNDED"
    assert L.send(L.investor, L.fin.functions.fund(onchain_id), expect_revert=True) is None  # duplicate funding

    # debtor (any third party) repays the face value; investor is paid; second repay reverts
    L.send(L.admin, L.usdt.functions.mint(L.payer.address, 2000 * 10**6))
    inv_before = L.usdt.functions.balanceOf(L.investor.address).call()
    L.send(L.payer, L.usdt.functions.approve(L.fin.address, 1000 * 10**6))
    r = L.send(L.payer, L.fin.functions.repay(onchain_id))
    L.mine(4)
    v = c.post(f"{API}/financing/verify-transaction", json={"tx_hash": "0x" + r.transactionHash.hex().removeprefix("0x")}, headers=adm["h"])
    assert v.status_code == 200 and v.json()["stage"] == "verified", v.text
    assert L.usdt.functions.balanceOf(L.investor.address).call() - inv_before == 1000 * 10**6
    assert c.get(f"{API}/financing/offers/{o['id']}", headers=investor["h"]).json()["status"] == "SETTLED"
    assert L.send(L.payer, L.fin.functions.repay(onchain_id), expect_revert=True) is None  # duplicate settlement
    assert w.invoice_row(inv["id"])["status"] == "PAID"


def test_flutter_selector_constants_match_compiled_abi(local):
    """Selectors hard-coded in app/lib/core/utils/abi.dart must equal the selectors of the compiled contracts."""
    dart = (ROOT / "app" / "lib" / "core" / "utils" / "abi.dart").read_text()
    consts = dict(__import__("re").findall(r"static const (\w+) = '([0-9a-f]{8})'", dart))
    expected = {
        "approve": local.usdt.functions.approve, "allowance": local.usdt.functions.allowance, "balanceOf": local.usdt.functions.balanceOf,
        "decimals": local.usdt.functions.decimals, "fund": local.fin.functions.fund, "repay": local.fin.functions.repay,
        "payInvoice": local.pay.functions.payInvoice, "registerInvoice": local.fin.functions.registerInvoice,
        "verifyInvoice": local.fin.functions.verifyInvoice, "createOffer": local.fin.functions.createOffer,
    }
    assert set(consts) == set(expected)
    from eth_utils import function_signature_to_4byte_selector as sel
    for name, abi_fn in (("approve", "approve(address,uint256)"), ("allowance", "allowance(address,address)"), ("balanceOf", "balanceOf(address)"),
                         ("decimals", "decimals()"), ("fund", "fund(uint256)"), ("repay", "repay(uint256)"),
                         ("payInvoice", "payInvoice((bytes32,bytes32,address,address,uint256,uint256,uint256,uint64),bytes)"),
                         ("registerInvoice", "registerInvoice((bytes32,bytes32,bytes32,address,address,uint256,uint64,uint64))"),
                         ("verifyInvoice", "verifyInvoice(uint256,bytes32)"), ("createOffer", "createOffer(uint256,uint256,uint64)")):
        assert sel(abi_fn).hex() == consts[name], name
    # and the function really exists in the compiled ABI with that exact signature
    for c, names in ((local.pay, ["payInvoice"]), (local.fin, ["registerInvoice", "verifyInvoice", "createOffer", "fund", "repay"])):
        have = {f["name"] for f in c.abi if f["type"] == "function"}
        assert set(names) <= have
