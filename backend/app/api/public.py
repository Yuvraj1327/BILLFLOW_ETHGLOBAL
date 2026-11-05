from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, Path

from app.core.config import Settings, get_settings
from app.core.database import transaction
from app.core.dependencies import public_rate_limit
from app.core.exceptions import AppError, not_found
from app.repositories import businesses as biz_repo
from app.repositories import invoices as inv_repo
from app.repositories import payments as pay_repo
from app.schemas.common import ERRORS
from app.schemas.public import PaymentIntentIn, PaymentIntentOut, PublicInvoiceOut, PublicStatusOut
from app.services import payment_service
from app.services._common import explorer_tx, money
from app.services.invoice_service import payable

router = APIRouter(prefix="/public/invoices", tags=["Public checkout"], responses=ERRORS, dependencies=[Depends(public_rate_limit)])
Cfg = Annotated[Settings, Depends(get_settings)]
Token = Annotated[str, Path(min_length=32, max_length=128, pattern=r"^[A-Za-z0-9_\-]+$")]


def _load(token: str):
    """Resolve token -> (invoice, business, link). Unknown token => 404; revoked/expired => 410."""
    with transaction() as c:
        link = inv_repo.link_by_token(c, token)
        if link is None:
            raise not_found("Payment link", "link_not_found")
        inv = inv_repo.get(c, link["invoice_id"])
        biz = biz_repo.get_business(c, inv["business_id"])
        pays = pay_repo.for_invoice(c, inv["id"])
        from datetime import datetime, timezone
        expired = link["revoked_at"] is not None or (link["expires_at"] and link["expires_at"] <= datetime.now(timezone.utc))
    if expired:
        raise AppError(410, "link_expired", "This payment link is no longer active")
    return inv, biz, link, pays


@router.get("/{token}", response_model=PublicInvoiceOut, summary="Invoice as shown on the checkout page (minimal data)")
def view(token: Token, s: Cfg):
    inv, biz, link, _ = _load(token)
    ok, why = payable(inv, biz["payout_wallet"])
    d = inv["token_decimals"]
    return {"merchant_name": biz["legal_name"], "invoice_number": inv["invoice_number"], "description": inv["description"],
            "amount": money(inv["amount_base"], d), "paid_amount": money(inv["paid_amount_base"], d),
            "remaining_amount": money(int(inv["amount_base"]) - int(inv["paid_amount_base"]), d), "currency": inv["currency"],
            "due_date": inv["due_date"], "status": inv["status"], "payable": ok, "payable_reason": why,
            "chain_id": s.whitechain_chain_id, "usdt_address": s.whitechain_usdt_address, "usdt_decimals": d,
            "payments_contract": s.whitechain_payment_contract, "link_expires_at": link["expires_at"]}


@router.post("/{token}/payment-intent", response_model=PaymentIntentOut,
             summary="Get a signed, single-use, expiring quote to pay with your own wallet")
def payment_intent(token: Token, body: PaymentIntentIn, s: Cfg):
    """The backend signs only an authorisation (EIP-712). The payer approves USDT and calls `payInvoice` from their own wallet;
    the invoice becomes PAID only after the transaction is verified on-chain."""
    inv, biz, _, _ = _load(token)
    return payment_service.create_quote(inv, biz["payout_wallet"], body.payer_wallet, body.amount, s)


@router.get("/{token}/status", response_model=PublicStatusOut, summary="Payment status for the checkout page")
def status(token: Token, s: Cfg):
    inv, biz, _, pays = _load(token)
    ok, _why = payable(inv, biz["payout_wallet"])
    d = inv["token_decimals"]
    return {"status": inv["status"], "amount": money(inv["amount_base"], d), "paid_amount": money(inv["paid_amount_base"], d),
            "remaining_amount": money(int(inv["amount_base"]) - int(inv["paid_amount_base"]), d), "payable": ok,
            "payments": [{"amount": money(p["amount_base"], d), "tx_hash": p["tx_hash"], "explorer_url": explorer_tx(s, p["tx_hash"]),
                          "confirmed_at": p["confirmed_at"]} for p in pays]}
