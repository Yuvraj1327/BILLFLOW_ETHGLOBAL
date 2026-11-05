"""Test doubles. THESE ARE MOCKS: nothing here talks to Whitechain, Supabase Auth/Storage or Anthropic."""
from __future__ import annotations

import io
import json
import secrets
import time
from dataclasses import dataclass, field
from typing import Any

import jwt
from eth_utils import keccak, to_checksum_address
from pypdf import PdfWriter
from web3 import Web3

from app.services.blockchain_service import ChainLog, ChainReceipt, load_abi

SECRET = "test-jwt-secret-test-jwt-secret-1234567890"
CHAIN_ID = 1874
DEC = 6

# Local fixtures only (deterministic, NOT real deployments).
USDT = "0x" + "11" * 20
PAYMENTS = "0x" + "22" * 20
FINANCING = "0x" + "33" * 20
OTHER_TOKEN = "0x" + "44" * 20
SIGNER_KEY = "0x" + "ab" * 32

CODEC = Web3().codec


def token(user_id, *, exp_in: int = 3600, secret: str = SECRET, aud: str = "authenticated", alg: str = "HS256", **extra) -> str:
    now = int(time.time())
    return jwt.encode({"sub": str(user_id), "aud": aud, "exp": now + exp_in, "iat": now, "role": "authenticated", **extra}, secret, algorithm=alg)


def pdf_bytes(tag: str = "a", pages: int = 1) -> bytes:
    w = PdfWriter()
    for _ in range(pages):
        w.add_blank_page(width=200, height=200)
    w.add_metadata({"/Title": f"invoice-{tag}-{secrets.token_hex(4)}"})
    b = io.BytesIO()
    w.write(b)
    return b.getvalue()


def h32(label: str) -> str:
    return "0x" + keccak(text=label).hex()


# ───────────────────────── ABI-correct log construction ─────────────────────────
def _event_abi(kind: str, name: str) -> dict:
    abi = {"payments": "BillFlowPayments", "financing": "InvoiceFinancing", "erc20": "ERC20"}[kind]
    return next(e for e in load_abi(abi) if e["type"] == "event" and e["name"] == name)


def _topic(typ: str, v: Any) -> str:
    if typ == "address":
        return "0x" + "00" * 12 + v[2:].lower()
    if typ == "bytes32":
        return v.lower()
    if typ.startswith("uint"):
        return "0x" + int(v).to_bytes(32, "big").hex()
    raise AssertionError(typ)


def make_log(kind: str, address: str, name: str, args: dict, *, tx_hash: str, log_index: int = 0, block: int = 100,
             block_hash: str | None = None) -> ChainLog:
    ev = _event_abi(kind, name)
    sig = f"{name}({','.join(i['type'] for i in ev['inputs'])})"
    topics = ["0x" + keccak(text=sig).hex()]
    d_types, d_vals = [], []
    for i in ev["inputs"]:
        v = args[i["name"]]
        if i["indexed"]:
            topics.append(_topic(i["type"], v))
        else:
            d_types.append(i["type"])
            d_vals.append(Web3.to_bytes(hexstr=v) if i["type"] == "bytes32" else (Web3.to_checksum_address(v) if i["type"] == "address" else v))
    data = "0x" + CODEC.encode(d_types, d_vals).hex()
    return ChainLog(address=address, topics=topics, data=data, log_index=log_index, block_number=block,
                    block_hash=block_hash or h32(f"block-{block}"), tx_hash=tx_hash)


def erc20_transfer(frm: str, to: str, value: int, **kw) -> ChainLog:
    return make_log("erc20", kw.pop("address", USDT), "Transfer", {"from": frm, "to": to, "value": value}, **kw)


def invoice_paid(inv: dict, payer: str, merchant: str, amount: int, total_paid: int, *, address: str = PAYMENTS, payment_id: int = 1, **kw) -> ChainLog:
    return make_log("payments", address, "InvoicePaid", {
        "invoiceId": inv["onchain_invoice_id"], "paymentId": payment_id, "payer": payer, "merchant": merchant, "amount": amount,
        "totalPaid": total_paid, "invoiceTotal": int(inv["amount_base"]), "invoiceHash": inv["invoice_hash"]}, **kw)


@dataclass
class FakeChain:
    """In-memory ChainClient. Receipts/logs are registered by tests; head advances manually."""
    cid: int = CHAIN_ID
    head: int = 200
    receipts: dict[str, ChainReceipt] = field(default_factory=dict)
    block_hashes: dict[int, str] = field(default_factory=dict)
    code: dict[str, bytes] = field(default_factory=dict)
    calls: dict[tuple, Any] = field(default_factory=dict)
    fail: bool = False

    def chain_id(self): return self.cid
    def latest_block(self): return self.head

    def get_receipt(self, tx_hash):
        return self.receipts.get(tx_hash.lower())

    def get_block_hash(self, number):
        return self.block_hashes.get(number)

    def get_logs(self, addresses, from_block, to_block):
        if self.fail:
            from app.core.exceptions import upstream
            raise upstream("rpc_unavailable", "down")
        addrs = {a.lower() for a in addresses}
        out = [lg for r in self.receipts.values() if r.status == 1 for lg in r.logs
               if lg.address.lower() in addrs and from_block <= lg.block_number <= to_block]
        return sorted(out, key=lambda x: (x.block_number, x.log_index))

    def get_code(self, address): return self.code.get(address.lower(), b"")

    def call(self, address, abi, fn, *args):
        return self.calls[(address.lower(), fn)]

    def add(self, tx_hash: str, logs: list[ChainLog], *, status: int = 1, block: int = 100, frm: str = "0x" + "99" * 20, to: str = PAYMENTS):
        for lg in logs:
            lg.block_number, lg.tx_hash = block, tx_hash
            lg.block_hash = h32(f"block-{block}")
        self.block_hashes[block] = h32(f"block-{block}")
        r = ChainReceipt(tx_hash=tx_hash, status=status, block_number=block, block_hash=h32(f"block-{block}"),
                         from_address=frm, to_address=to, logs=logs)
        self.receipts[tx_hash.lower()] = r
        return r


class FakeAuth:
    def __init__(self): self.users = {}; self.logged_out = []
    def signup(self, email, password, role, display_name):
        self.users[email] = (password, role)
        return {"id": "00000000-0000-0000-0000-000000000001", "email": email}
    def login(self, email, password):
        from app.core.exceptions import unauthorized
        if self.users.get(email, (None,))[0] != password:
            raise unauthorized("Invalid email or password", "invalid_credentials")
        return {"access_token": "at", "refresh_token": "rt", "expires_in": 3600, "user": {"id": "00000000-0000-0000-0000-000000000001", "email": email}}
    def refresh(self, rt): return {"access_token": "at2", "refresh_token": "rt2", "expires_in": 3600, "user": {"id": "00000000-0000-0000-0000-000000000001", "email": "x@x.io"}}
    def logout(self, at): self.logged_out.append(at)


class FakeStorage:
    def __init__(self): self.objects: dict[str, bytes] = {}
    def upload(self, path, data, content_type): self.objects[path] = data
    def download(self, path): return self.objects[path]
    def signed_url(self, path, expires_in=300): return f"https://storage.test/{path}?sig=1"
    def remove(self, path): self.objects.pop(path, None)


class FakeLLM:
    """Returns canned tool input (or raises). Records what it was sent so tests can assert on data minimisation."""
    def __init__(self): self.response: Any = {}; self.exc: Exception | None = None; self.calls: list[dict] = []
    def call_tool(self, *, system, content, tool_name, schema, max_tokens):
        self.calls.append({"system": system, "content": content, "tool": tool_name, "schema": schema})
        if self.exc:
            raise self.exc
        return self.response
