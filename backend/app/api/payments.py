from __future__ import annotations

from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Path

from app.core.config import Settings, get_settings
from app.core.dependencies import AnyUser, Pagination
from app.schemas.common import ERRORS, Page
from app.schemas.payment import PaymentOut, TX_HASH, TxVerificationOut, VerifyTxIn
from app.services import payment_service as svc

router = APIRouter(prefix="/payments", tags=["Payments"], responses=ERRORS)
Cfg = Annotated[Settings, Depends(get_settings)]


@router.post("/verify", response_model=TxVerificationOut,
             summary="Verify a payment transaction on-chain (the client's claim of success is never trusted)")
def verify(body: VerifyTxIn, user: AnyUser, s: Cfg):
    """Pipeline: chain id -> receipt -> status -> confirmations -> canonical block -> events from the configured contract ->
    matching transfer from the configured USDT -> invoice/merchant/amount checks -> idempotent write.
    `stage`: not_found | submitted | failed | confirmed | rejected | verified."""
    return svc.verify(user, body.tx_hash, s)


@router.get("", response_model=Page[PaymentOut], summary="Payments visible to me (merchant: my business; others: from my wallet)")
def list_(user: AnyUser, pg: Pagination, s: Cfg, invoice_id: UUID | None = None):
    rows, total = svc.list_(user, invoice_id, pg, s)
    return Page(items=rows, page=pg.page, page_size=pg.page_size, total=total)


@router.get("/invoice/{invoice_id}", response_model=list[PaymentOut], summary="Payments of one invoice")
def by_invoice(invoice_id: UUID, user: AnyUser, s: Cfg):
    return svc.for_invoice(user, invoice_id, s)


@router.get("/transaction/{tx_hash}", response_model=list[PaymentOut], summary="Payments recorded for a tx hash")
def by_tx(user: AnyUser, s: Cfg, tx_hash: Annotated[str, Path(pattern=TX_HASH)]):
    return svc.by_tx(user, tx_hash, s)


@router.get("/{payment_id}", response_model=PaymentOut, summary="One payment")
def get(payment_id: UUID, user: AnyUser, s: Cfg):
    return svc.get(user, payment_id, s)
