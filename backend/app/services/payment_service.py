"""Payment quotes (EIP-712, signed by the backend quote signer) and independent payment verification.

The backend NEVER signs or submits a payer's transaction and never holds payer keys: it only signs a *quote*
(an authorisation the contract checks), and the payer's wallet sends the payInvoice transaction itself.
"""
from __future__ import annotations

import logging
import time
from decimal import Decimal

from eth_account import Account
from eth_account.messages import encode_typed_data

from app.core.config import Settings
from app.core.database import transaction
from app.core.dependencies import CurrentUser, PageParams
from app.core.exceptions import bad_request, conflict, forbidden, not_found, unavailable
from app.core.security import random_uint256
from app.repositories import businesses as biz_repo
from app.repositories import invoices as inv_repo
from app.repositories import payments as pay_repo
from app.repositories.system import audit
from app.services._common import decimals, explorer_tx, money
from app.services.blockchain_service import get_blockchain
from app.services.event_processor import verify_transaction
from app.services.invoice_service import payable
from app.utils.validators import checksum, norm_address, to_base

log = logging.getLogger("billflow.payments")


def signer_address(s: Settings) -> str | None:
    if not s.quote_signer_private_key:
        return None
    return Account.from_key(s.quote_signer_private_key).address.lower()


def _require_ready(s: Settings) -> None:
    for name, val in (("QUOTE_SIGNER_PRIVATE_KEY", s.quote_signer_private_key), ("WHITECHAIN_PAYMENT_CONTRACT", s.whitechain_payment_contract),
                      ("WHITECHAIN_USDT_ADDRESS", s.whitechain_usdt_address)):
        if not val:
            raise unavailable("payments_not_configured", f"{name} is not configured")


def create_quote(inv: dict, payout_wallet: str, payer_wallet: str, amount: str | None, s: Settings) -> dict:
    """Validate, sign and persist a single-use quote. Caller has already loaded the invoice (without locking)."""
    _require_ready(s)
    dec = inv["token_decimals"]
    payer = norm_address(payer_wallet, "payer_wallet")
    ok, why = payable(inv, payout_wallet)
    if not ok:
        raise conflict("invoice_not_payable", why or "Invoice is not payable")
    remaining = int(inv["amount_base"]) - int(inv["paid_amount_base"])
    if remaining <= 0:
        raise conflict("invoice_not_payable", "Invoice has nothing left to pay")
    pay_amount = to_base(amount, dec, "amount") if amount is not None else remaining
    if pay_amount > remaining:
        raise bad_request("amount_exceeds_remaining", "Amount exceeds the remaining balance",
                          remaining=money(remaining, dec))
    nonce = random_uint256()
    expiry = int(time.time()) + s.quote_ttl_seconds
    quote = {"invoiceId": inv["onchain_invoice_id"], "invoiceHash": inv["invoice_hash"], "merchant": checksum(payout_wallet),
             "payer": checksum(payer), "amount": pay_amount, "invoiceTotal": int(inv["amount_base"]), "nonce": nonce, "expiry": expiry}
    domain = {"name": "BillFlowPayments", "version": "1", "chainId": s.whitechain_chain_id,
              "verifyingContract": checksum(s.whitechain_payment_contract)}
    types = {"EIP712Domain": [{"name": "name", "type": "string"}, {"name": "version", "type": "string"},
                              {"name": "chainId", "type": "uint256"}, {"name": "verifyingContract", "type": "address"}],
             "Quote": [{"name": "invoiceId", "type": "bytes32"}, {"name": "invoiceHash", "type": "bytes32"},
                       {"name": "merchant", "type": "address"}, {"name": "payer", "type": "address"},
                       {"name": "amount", "type": "uint256"}, {"name": "invoiceTotal", "type": "uint256"},
                       {"name": "nonce", "type": "uint256"}, {"name": "expiry", "type": "uint64"}]}
    msg = encode_typed_data(full_message={"types": types, "primaryType": "Quote", "domain": domain, "message": quote})
    sig = Account.sign_message(msg, private_key=s.quote_signer_private_key).signature.hex()
    sig = sig if sig.startswith("0x") else "0x" + sig
    with transaction() as c:
        row = inv_repo.add_quote(c, inv["id"], payer, pay_amount, nonce, s.quote_ttl_seconds)
    return {"chain_id": s.whitechain_chain_id, "payments_contract": checksum(s.whitechain_payment_contract),
            "usdt_address": checksum(s.whitechain_usdt_address), "usdt_decimals": dec, "approve_amount_base": str(pay_amount),
            "quote": {**quote, "amount": str(pay_amount), "invoiceTotal": str(int(inv["amount_base"])), "nonce": str(nonce),
                      "expiry": str(expiry)},
            "signature": sig, "quote_expires_at": row["expiry"], "eip712_domain": domain,
            "instructions": "1) USDT.approve(payments_contract, approve_amount_base)  2) BillFlowPayments.payInvoice(quote, signature) "
                            "from the payer wallet  3) report the tx hash; the backend verifies it on-chain."}


# ───────────────────────── verification & queries ─────────────────────────
def _view(p: dict, s: Settings) -> dict:
    d = p["token_decimals"]
    return {"id": p["id"], "invoice_id": p["invoice_id"], "invoice_number": p.get("invoice_number"), "payer_wallet": p["payer_wallet"],
            "amount": money(p["amount_base"], d), "amount_base": str(int(p["amount_base"])), "tx_hash": p["tx_hash"],
            "log_index": p["log_index"], "block_number": p["block_number"], "status": p["status"], "confirmed_at": p["confirmed_at"],
            "explorer_url": explorer_tx(s, p["tx_hash"])}


def _business_id_of(user: CurrentUser) -> str | None:
    with transaction() as c:
        b = biz_repo.business_of_user(c, user.id)
    return b["id"] if b else None


def _can_see(user: CurrentUser, p: dict, my_business) -> bool:
    return (user.role == "admin" or (my_business is not None and p["business_id"] == my_business)
            or (user.wallet_address is not None and p["payer_wallet"] == user.wallet_address))


def verify(user: CurrentUser, tx_hash: str, s: Settings) -> dict:
    """Independently verify a client-supplied hash. The client's claim of success is never used."""
    res = verify_transaction(get_blockchain(s), tx_hash, ("payments",))
    out = {k: getattr(res, k) for k in ("tx_hash", "stage", "detail", "confirmations", "required_confirmations", "block_number",
                                        "explorer_url", "events", "payment_ids")}
    out["offer_ids"] = []
    if res.stage in ("verified", "confirmed") and user.role != "admin":
        mine = _business_id_of(user) if user.role == "merchant" else None
        with transaction() as c:
            rows = pay_repo.by_tx(c, res.tx_hash)
        if not any(_can_see(user, p, mine) for p in rows):
            out["events"], out["payment_ids"] = [], []
            out["detail"] = "Transaction verified but it is not related to your account"
    return out


def list_(user: CurrentUser, invoice_id, pg: PageParams, s: Settings):
    with transaction() as c:
        if user.role == "admin":
            rows, total = pay_repo.list_(c, invoice_id=invoice_id, pg=pg)
        elif user.role == "merchant":
            biz = biz_repo.business_of_user(c, user.id)
            if not biz:
                return [], 0
            rows, total = pay_repo.list_(c, business_id=biz["id"], invoice_id=invoice_id, pg=pg)
        elif user.wallet_address:
            rows, total = pay_repo.list_(c, payer_wallet=user.wallet_address, invoice_id=invoice_id, pg=pg)
        else:
            return [], 0
    return [_view(p, s) for p in rows], total


def _checked(user: CurrentUser, rows: list[dict]) -> list[dict]:
    mine = _business_id_of(user) if user.role == "merchant" else None
    vis = [p for p in rows if _can_see(user, p, mine)]
    if not vis:
        raise not_found("Payment", "payment_not_found")  # no existence oracle
    return vis


def get(user: CurrentUser, payment_id, s: Settings) -> dict:
    with transaction() as c:
        p = pay_repo.get(c, payment_id)
    if p is None:
        raise not_found("Payment", "payment_not_found")
    return _view(_checked(user, [p])[0], s)


def for_invoice(user: CurrentUser, invoice_id, s: Settings) -> list[dict]:
    with transaction() as c:
        inv = inv_repo.get(c, invoice_id)
        rows = pay_repo.for_invoice(c, invoice_id)
    if inv is None:
        raise not_found("Invoice", "invoice_not_found")
    mine = _business_id_of(user) if user.role == "merchant" else None
    if user.role == "admin" or (mine is not None and inv["business_id"] == mine):
        return [_view(p, s) for p in rows]  # owner sees all (possibly none)
    return [_view(p, s) for p in _checked(user, rows)]


def by_tx(user: CurrentUser, tx_hash: str, s: Settings) -> list[dict]:
    with transaction() as c:
        rows = pay_repo.by_tx(c, tx_hash.lower())
    return [_view(p, s) for p in _checked(user, rows)]
