"""Refunds (merchant-initiated, executed through BillFlowRefunds). The backend only PREPARES the request and later VERIFIES the
resulting on-chain event; it never signs a refund and never holds the merchant's key. A refund is CONFIRMED only after the
`PaymentRefunded` event is verified (receipt, confirmations, USDT transfer merchant -> original payer, payment/amount/party checks)."""
from __future__ import annotations

import logging

from app.core.config import Settings
from app.core.database import transaction
from app.core.dependencies import BusinessCtx, CurrentUser, PageParams
from app.core.exceptions import bad_request, conflict, not_found, unavailable
from app.core.security import random_uint256
from app.repositories import payments as pay_repo
from app.repositories import refunds as repo
from app.repositories.system import audit
from app.services._common import explorer_tx, money
from app.services.blockchain_service import get_blockchain, load_abi
from app.services.event_processor import verify_transaction
from app.utils.validators import checksum, keccak_hex, to_base

log = logging.getLogger("billflow.refunds")


def _require_ready(s: Settings) -> None:
    if not s.whitechain_refunds_contract:
        raise unavailable("refunds_not_configured", "WHITECHAIN_REFUNDS_CONTRACT is not configured")


def serialize(r: dict, s: Settings) -> dict:
    d = r["token_decimals"]
    return {"id": r["id"], "payment_id": r["payment_id"], "invoice_id": r["invoice_id"], "invoice_number": r.get("invoice_number"),
            "amount": money(r["amount_base"], d), "amount_base": str(int(r["amount_base"])), "status": r["status"],
            "refund_ref": r["refund_ref"], "reason_hash": r["reason_hash"], "payer_wallet": r.get("payer_wallet"),
            "onchain_payment_id": str(int(r["onchain_payment_id"])) if r.get("onchain_payment_id") is not None else None,
            "onchain_refund_id": str(int(r["onchain_refund_id"])) if r.get("onchain_refund_id") is not None else None,
            "tx_hash": r["tx_hash"], "explorer_url": explorer_tx(s, r["tx_hash"]), "refunded_at": r["refunded_at"],
            "created_at": r["created_at"]}


def prepare(ctx: BusinessCtx, payment_id, amount: str | None, amount_base: str | None, reason: str | None, s: Settings) -> dict:
    """Validate and record a PENDING refund request; returns exactly what the merchant wallet must sign."""
    _require_ready(s)
    with transaction() as c:
        p = pay_repo.get(c, payment_id)
        if p is None or p["business_id"] != ctx.business_id:
            raise not_found("Payment", "payment_not_found")  # no existence oracle across businesses
        if p["status"] != "CONFIRMED":
            raise conflict("payment_not_confirmed", "Only confirmed payments can be refunded")
        if p.get("onchain_payment_id") is None:
            raise conflict("payment_not_refundable", "This payment predates refund support (no on-chain payment id recorded)")
        d = p["token_decimals"]
        if (amount is None) == (amount_base is None):
            raise bad_request("invalid_amount", "Provide exactly one of `amount` or `amount_base`")
        amt = int(amount_base) if amount_base is not None else to_base(amount, d, "amount")
        refundable = int(p["amount_base"]) - int(p["refunded_amount_base"])
        if amt <= 0:
            raise bad_request("invalid_amount", "Refund amount must be positive")
        if amt > refundable:
            raise bad_request("refund_exceeds_payment", "Refund exceeds the refundable amount of this payment",
                              refundable=money(refundable, d))
        from app.repositories.businesses import get_business
        wallet = get_business(c, ctx.business_id)["payout_wallet"]
        ref = "0x" + random_uint256().to_bytes(32, "big").hex()
        reason_hash = keccak_hex((reason or "").encode())
        row = repo.insert_pending(c, {"payment_id": p["id"], "invoice_id": p["invoice_id"], "business_id": ctx.business_id,
                                      "amount_base": amt, "refund_ref": ref, "reason": reason, "reason_hash": reason_hash,
                                      "requested_by": ctx.user.id})
        audit(c, ctx.user.id, "refund_requested", "refund", row["id"], {"payment_id": str(p["id"]), "amount_base": str(amt)})
        out = repo.get(c, row["id"])
    res = serialize(out, s)
    res["signer_wallet"] = wallet
    res["plan"] = {
        "chain_id": s.whitechain_chain_id,
        "steps": [
            {"step": "approve", "contract": checksum(s.whitechain_usdt_address), "function": "approve",
             "args": {"spender": checksum(s.whitechain_refunds_contract), "amount": str(amt)}, "signer": wallet},
            {"step": "refund", "contract": checksum(s.whitechain_refunds_contract), "function": "refund",
             "args": {"paymentId": str(int(p["onchain_payment_id"])), "amount": str(amt), "refundRef": ref, "reasonHash": reason_hash},
             "signer": wallet}],
        "note": "Must be sent by the merchant payout wallet. The refund goes to the ORIGINAL payer recorded on-chain. "
                "It is CONFIRMED only after the event is verified; report the tx hash to POST /refunds/verify."}
    return res


def verify(user: CurrentUser, tx_hash: str, s: Settings) -> dict:
    _require_ready(s)
    res = verify_transaction(get_blockchain(s), tx_hash, ("refunds",))
    out = {k: getattr(res, k) for k in ("tx_hash", "stage", "detail", "confirmations", "required_confirmations", "block_number",
                                        "explorer_url", "events")}
    with transaction() as c:
        rows = c.execute(repo._J + " where r.tx_hash=%s order by r.log_index", (res.tx_hash,)).fetchall()
        mine = None
        if user.role != "admin":
            from app.repositories.businesses import business_of_user
            b = business_of_user(c, user.id)
            mine = b["id"] if b else None
    out["refunds"] = [serialize(r, s) for r in rows if user.role == "admin" or (mine is not None and r["business_id"] == mine)]
    return out


def get(ctx: BusinessCtx, refund_id, s: Settings) -> dict:
    with transaction() as c:
        r = repo.get(c, refund_id)
    if r is None or r["business_id"] != ctx.business_id:
        raise not_found("Refund", "refund_not_found")
    return serialize(r, s)


def list_(ctx: BusinessCtx, status: str | None, pg: PageParams, s: Settings):
    with transaction() as c:
        rows, total = repo.list_(c, ctx.business_id, status, pg)
    return [serialize(r, s) for r in rows], total


def cancel_pending(ctx: BusinessCtx, refund_id, s: Settings) -> dict:
    """Withdraw a request that was never sent. If its transaction is mined later, the on-chain fact still wins (see event processor)."""
    with transaction() as c:
        r = repo.get(c, refund_id, lock=True)
        if r is None or r["business_id"] != ctx.business_id:
            raise not_found("Refund", "refund_not_found")
        if r["status"] != "PENDING":
            raise conflict("invalid_transition", f"Only PENDING refund requests can be cancelled (this one is {r['status']})")
        c.execute("update refunds set status='CANCELLED' where id=%s", (refund_id,))
        audit(c, ctx.user.id, "refund_request_cancelled", "refund", refund_id)
        out = repo.get(c, refund_id)
    return serialize(out, s)


def chain_check(ctx: BusinessCtx, refund_id, s: Settings) -> dict:
    """Re-read the refund from the contract and compare with our record (independent verification, read-only)."""
    _require_ready(s)
    with transaction() as c:
        r = repo.get(c, refund_id)
    if r is None or r["business_id"] != ctx.business_id:
        raise not_found("Refund", "refund_not_found")
    if r["status"] != "CONFIRMED" or r["onchain_refund_id"] is None:
        return {"refund": serialize(r, s), "checked": False, "reason": f"refund is {r['status']}; nothing to compare on-chain yet"}
    chain = get_blockchain(s)
    abi, addr = load_abi("BillFlowRefunds"), s.whitechain_refunds_contract
    rec = chain.client.call(addr, abi, "getRefund", int(r["onchain_refund_id"]))
    total = int(chain.client.call(addr, abi, "totalRefunded", int(r["onchain_payment_id"])))
    ok = (int(rec[0]) == int(r["onchain_payment_id"]) and int(rec[3]) == int(r["amount_base"])
          and "0x" + bytes(rec[4]).hex() == r["refund_ref"] and str(rec[1]).lower() == r["payer_wallet"])
    return {"refund": serialize(r, s), "checked": True, "matches_chain": bool(ok),
            "onchain_total_refunded_base": str(total), "contract": s.whitechain_refunds_contract}
