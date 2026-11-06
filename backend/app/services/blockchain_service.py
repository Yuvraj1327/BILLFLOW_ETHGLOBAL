"""Whitechain access: RPC client, ABI decoding, receipt verification helpers and deployment preflight.

Nothing here signs user transactions or holds user keys. The only key the backend ever uses is the
EIP-712 quote signer (see payment_service) and it never moves funds.
"""
from __future__ import annotations

import json
import logging
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path
from typing import Any, Protocol

from eth_utils import keccak
from hexbytes import HexBytes
from web3 import Web3
from web3._utils.events import get_event_data
from web3.exceptions import TransactionNotFound

from app.core.config import Settings, get_settings
from app.core.exceptions import AppError, unavailable, upstream

log = logging.getLogger("billflow.chain")
ABI_DIR = Path(__file__).resolve().parent.parent / "abi"


def load_abi(name: str) -> list[dict]:
    return json.loads((ABI_DIR / f"{name}.json").read_text())


# ───────────────────────── plain data carriers (also used by test doubles) ─────────────────────────
@dataclass
class ChainLog:
    address: str
    topics: list[str]
    data: str
    log_index: int
    block_number: int
    block_hash: str
    tx_hash: str


@dataclass
class ChainReceipt:
    tx_hash: str
    status: int
    block_number: int
    block_hash: str
    from_address: str
    to_address: str | None
    logs: list[ChainLog] = field(default_factory=list)


@dataclass
class DecodedEvent:
    chain_id: int
    contract: str  # lower-case address
    kind: str  # payments | financing | refunds | erc20
    name: str
    tx_hash: str
    log_index: int
    block_number: int
    block_hash: str
    args: dict[str, Any]  # JSON-safe: addresses lower-case, bytes as 0x hex, integers as decimal strings


class ChainClient(Protocol):
    def chain_id(self) -> int: ...
    def latest_block(self) -> int: ...
    def get_receipt(self, tx_hash: str) -> ChainReceipt | None: ...
    def get_block_hash(self, number: int) -> str | None: ...
    def get_logs(self, addresses: list[str], from_block: int, to_block: int) -> list[ChainLog]: ...
    def get_code(self, address: str) -> bytes: ...
    def call(self, address: str, abi: list[dict], fn: str, *args: Any) -> Any: ...


class Web3Chain:
    """Real JSON-RPC client. All transport failures become a 502 `rpc_unavailable`."""

    def __init__(self, rpc_url: str, timeout: float = 15.0):
        self.w3 = Web3(Web3.HTTPProvider(rpc_url, request_kwargs={"timeout": timeout}))

    @staticmethod
    def _wrap(fn):
        def inner(*a, **k):
            try:
                return fn(*a, **k)
            except AppError:
                raise
            except TransactionNotFound:
                raise
            except Exception as e:  # noqa: BLE001
                log.warning("rpc error: %s", type(e).__name__)
                raise upstream("rpc_unavailable", "Whitechain RPC request failed")
        return inner

    @staticmethod
    def _log(raw: Any) -> ChainLog:
        return ChainLog(address=raw["address"].lower(), topics=[HexBytes(t).hex() if str(HexBytes(t).hex()).startswith("0x")
                        else "0x" + HexBytes(t).hex() for t in raw["topics"]],
                        data="0x" + HexBytes(raw["data"]).hex().removeprefix("0x"), log_index=raw["logIndex"],
                        block_number=raw["blockNumber"], block_hash="0x" + HexBytes(raw["blockHash"]).hex().removeprefix("0x"),
                        tx_hash="0x" + HexBytes(raw["transactionHash"]).hex().removeprefix("0x"))

    @_wrap
    def chain_id(self) -> int:
        return int(self.w3.eth.chain_id)

    @_wrap
    def latest_block(self) -> int:
        return int(self.w3.eth.block_number)

    def get_receipt(self, tx_hash: str) -> ChainReceipt | None:
        try:
            r = self._receipt(tx_hash)
        except TransactionNotFound:
            return None
        return r

    @_wrap
    def _receipt(self, tx_hash: str) -> ChainReceipt:
        r = self.w3.eth.get_transaction_receipt(tx_hash)
        return ChainReceipt(tx_hash=tx_hash.lower(), status=int(r["status"]), block_number=int(r["blockNumber"]),
                            block_hash="0x" + HexBytes(r["blockHash"]).hex().removeprefix("0x"),
                            from_address=r["from"].lower(), to_address=(r["to"].lower() if r.get("to") else None),
                            logs=[self._log(x) for x in r["logs"]])

    @_wrap
    def get_block_hash(self, number: int) -> str | None:
        try:
            b = self.w3.eth.get_block(number)
        except Exception:  # block missing
            return None
        return "0x" + HexBytes(b["hash"]).hex().removeprefix("0x")

    @_wrap
    def get_logs(self, addresses: list[str], from_block: int, to_block: int) -> list[ChainLog]:
        raw = self.w3.eth.get_logs({"fromBlock": from_block, "toBlock": to_block,
                                    "address": [Web3.to_checksum_address(a) for a in addresses]})
        return [self._log(x) for x in raw]

    @_wrap
    def get_code(self, address: str) -> bytes:
        return bytes(self.w3.eth.get_code(Web3.to_checksum_address(address)))

    @_wrap
    def call(self, address: str, abi: list[dict], fn: str, *args: Any) -> Any:
        c = self.w3.eth.contract(address=Web3.to_checksum_address(address), abi=abi)
        return getattr(c.functions, fn)(*args).call()


# ───────────────────────── decoding ─────────────────────────
def _jsonable(v: Any) -> Any:
    if isinstance(v, (bytes, bytearray, HexBytes)):
        return "0x" + bytes(v).hex()
    if isinstance(v, bool):
        return v
    if isinstance(v, int):
        return str(v)
    if isinstance(v, str) and v.startswith("0x") and len(v) == 42:
        return v.lower()
    return v


class EventDecoder:
    """Topic0 -> event ABI for the two BillFlow contracts (+ ERC-20 Transfer). Built from the shipped ABIs."""

    def __init__(self, settings: Settings):
        self.s = settings
        self.codec = Web3().codec
        self.by_address: dict[str, str] = {}
        if settings.whitechain_payment_contract:
            self.by_address[settings.whitechain_payment_contract] = "payments"
        if settings.whitechain_financing_contract:
            self.by_address[settings.whitechain_financing_contract] = "financing"
        if settings.whitechain_refunds_contract:
            self.by_address[settings.whitechain_refunds_contract] = "refunds"
        if settings.whitechain_usdt_address:
            self.by_address[settings.whitechain_usdt_address] = "erc20"
        self.events: dict[str, dict[str, dict]] = {"payments": {}, "financing": {}, "refunds": {}, "erc20": {}}
        for kind, abi_name in (("payments", "BillFlowPayments"), ("financing", "InvoiceFinancing"),
                               ("refunds", "BillFlowRefunds"), ("erc20", "ERC20")):
            for item in load_abi(abi_name):
                if item["type"] == "event":
                    sig = f"{item['name']}({','.join(self._canon(i) for i in item['inputs'])})"
                    self.events[kind]["0x" + keccak(text=sig).hex()] = item

    @staticmethod
    def _canon(inp: dict) -> str:
        t = inp["type"]
        if t.startswith("tuple"):
            inner = ",".join(EventDecoder._canon(c) for c in inp["components"])
            return f"({inner}){t[5:]}"
        return t

    def decode(self, lg: ChainLog) -> DecodedEvent | None:
        kind = self.by_address.get(lg.address.lower())
        if kind is None or not lg.topics:
            return None
        abi = self.events[kind].get(lg.topics[0].lower())
        if abi is None:
            return None
        entry = {"address": lg.address, "topics": [HexBytes(t) for t in lg.topics], "data": HexBytes(lg.data),
                 "logIndex": lg.log_index, "blockNumber": lg.block_number, "blockHash": HexBytes(lg.block_hash),
                 "transactionHash": HexBytes(lg.tx_hash), "transactionIndex": 0}
        try:
            parsed = get_event_data(self.codec, abi, entry)
        except Exception:  # undecodable under our ABI -> treat as foreign
            log.warning("could not decode %s log in %s", abi["name"], lg.tx_hash)
            return None
        args = {k: _jsonable(v) for k, v in dict(parsed["args"]).items()}
        return DecodedEvent(chain_id=self.s.whitechain_chain_id, contract=lg.address.lower(), kind=kind, name=abi["name"],
                            tx_hash=lg.tx_hash.lower(), log_index=lg.log_index, block_number=lg.block_number,
                            block_hash=lg.block_hash.lower(), args=args)


# ───────────────────────── service ─────────────────────────
class BlockchainService:
    def __init__(self, client: ChainClient, settings: Settings):
        self.client, self.s = client, settings
        self.decoder = EventDecoder(settings)

    @property
    def contract_addresses(self) -> list[str]:
        return [a for a in (self.s.whitechain_payment_contract, self.s.whitechain_financing_contract,
                            self.s.whitechain_refunds_contract) if a]

    def explorer_tx_url(self, tx_hash: str) -> str:
        return f"{self.s.whitechain_explorer_url.rstrip('/')}/tx/{tx_hash}"

    def assert_network(self) -> None:
        cid = self.client.chain_id()
        if cid != self.s.whitechain_chain_id:
            raise AppError(502, "wrong_network", f"RPC reports chain {cid}, expected {self.s.whitechain_chain_id}")

    def confirmations(self, receipt: ChainReceipt) -> int:
        return max(0, self.client.latest_block() - receipt.block_number + 1)

    def decode_receipt(self, receipt: ChainReceipt, kinds: tuple[str, ...] = ("payments", "financing", "refunds")) -> list[DecodedEvent]:
        out = []
        for lg in receipt.logs:
            ev = self.decoder.decode(lg)
            if ev and ev.kind in kinds:
                out.append(ev)
        return out

    def usdt_transfers(self, receipt: ChainReceipt) -> list[DecodedEvent]:
        """Transfer logs emitted by the configured USDT contract only (any other token is ignored)."""
        return [e for e in self.decode_receipt(receipt, ("erc20",)) if e.name == "Transfer"
                and e.contract == self.s.whitechain_usdt_address]

    def erc20_decimals(self, token: str | None = None) -> int:
        return int(self.client.call(token or self.s.whitechain_usdt_address, load_abi("ERC20"), "decimals"))

    def usdt_balance(self, owner: str) -> int:
        from web3 import Web3 as _W
        return int(self.client.call(self.s.whitechain_usdt_address, load_abi("ERC20"), "balanceOf", _W.to_checksum_address(owner)))

    def preflight(self, signer_address: str | None = None) -> dict[str, dict[str, Any]]:
        """Check that configured addresses really are the expected deployed contracts. Never assumes."""
        s, checks = self.s, {}

        def rec(name: str, ok: bool, detail: Any = "") -> None:
            checks[name] = {"ok": bool(ok), "detail": detail}

        try:
            rec("chain_id", self.client.chain_id() == s.whitechain_chain_id, self.client.chain_id())
            for label, addr in (("usdt", s.whitechain_usdt_address), ("payments", s.whitechain_payment_contract),
                                ("financing", s.whitechain_financing_contract)):
                rec(f"{label}_has_code", bool(addr) and len(self.client.get_code(addr)) > 0, addr or "not configured")
            if s.whitechain_usdt_address:
                dec = self.erc20_decimals()
                rec("usdt_decimals", s.usdt_decimals is not None and dec == s.usdt_decimals,
                    {"onchain": dec, "configured": s.usdt_decimals})
            if s.whitechain_payment_contract:
                tok = self.client.call(s.whitechain_payment_contract, load_abi("BillFlowPayments"), "PAYMENT_TOKEN")
                rec("payments_token_matches", tok.lower() == s.whitechain_usdt_address, tok.lower())
                qs = self.client.call(s.whitechain_payment_contract, load_abi("BillFlowPayments"), "quoteSigner")
                rec("quote_signer_matches", signer_address is not None and qs.lower() == signer_address.lower(), qs.lower())
            if s.whitechain_refunds_contract:
                rc = s.whitechain_refunds_contract
                rec("refunds_has_code", len(self.client.get_code(rc)) > 0, rc)
                tok = self.client.call(rc, load_abi("BillFlowRefunds"), "PAYMENT_TOKEN")
                rec("refunds_token_matches", tok.lower() == s.whitechain_usdt_address, tok.lower())
                pc = self.client.call(rc, load_abi("BillFlowRefunds"), "PAYMENTS")
                rec("refunds_points_at_payments", pc.lower() == s.whitechain_payment_contract, pc.lower())
            if s.whitechain_financing_contract:
                tok = self.client.call(s.whitechain_financing_contract, load_abi("InvoiceFinancing"), "PAYMENT_TOKEN")
                rec("financing_token_matches", tok.lower() == s.whitechain_usdt_address, tok.lower())
                self.client.call(s.whitechain_financing_contract, load_abi("InvoiceFinancing"), "invoiceCount")
                rec("financing_abi_callable", True)
            if s.whitechain_invoice_registry:
                rec("registry_equals_financing", s.whitechain_invoice_registry == s.whitechain_financing_contract,
                    "Step 2 merged the registry into InvoiceFinancing")
        except AppError as e:
            rec("rpc", False, e.message)
        except Exception as e:  # noqa: BLE001 — ABI/contract mismatch surfaces here
            rec("contract_calls", False, f"{type(e).__name__}: {e}"[:200])
        return checks


@lru_cache
def _default_client() -> ChainClient:
    s = get_settings()
    if not s.whitechain_rpc_url:
        raise unavailable("rpc_not_configured", "WHITECHAIN_RPC_URL is not configured")
    return Web3Chain(s.whitechain_rpc_url)


_override: ChainClient | None = None


def set_chain_client(client: ChainClient | None) -> None:
    """Test hook / alternative transport."""
    global _override
    _override = client


def get_blockchain(settings: Settings | None = None) -> BlockchainService:
    s = settings or get_settings()
    return BlockchainService(_override or _default_client(), s)
