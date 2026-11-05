from __future__ import annotations

from typing import Annotated, Literal
from uuid import UUID

from fastapi import APIRouter, Depends

from app.core.config import Settings, get_settings
from app.core.dependencies import Admin, AnyUser, MerchantBiz, Pagination
from app.schemas.common import ERRORS, Page
from app.schemas.financing import (FinancingOfferChainStatus, FinancingSubmit, FinancingVerifyIn, InvestmentOut, OfferOut, PublishOut)
from app.schemas.payment import TxVerificationOut, VerifyTxIn
from app.services import financing_service as svc

router = APIRouter(prefix="/financing", tags=["Financing"], responses=ERRORS)
Cfg = Annotated[Settings, Depends(get_settings)]
FStatus = Literal["REQUESTED", "UNDER_REVIEW", "APPROVED", "LISTED", "FUNDED", "SETTLED", "REJECTED", "EXPIRED", "CANCELLED", "DEFAULTED"]


@router.post("/submit", response_model=OfferOut, status_code=201,
             summary="Merchant requests financing for an invoice (status REQUESTED; nothing happens on-chain)")
def submit(body: FinancingSubmit, ctx: MerchantBiz, s: Cfg):
    return svc.submit(ctx, body, s)


@router.get("/offers", response_model=Page[OfferOut],
            summary="Offers visible to me (merchant: mine; investor: LISTED/active; admin: all)")
def offers(user: AnyUser, pg: Pagination, s: Cfg, status: FStatus | None = None):
    rows, total = svc.list_offers(user, status, pg, s)
    return Page(items=rows, page=pg.page, page_size=pg.page_size, total=total)


@router.get("/offers/{offer_id}", response_model=OfferOut, summary="One offer")
def offer(offer_id: UUID, user: AnyUser, s: Cfg):
    return svc.get_offer(user, offer_id, s)


@router.post("/offers/{offer_id}/verify", response_model=OfferOut, summary="Admin review: start_review | approve | reject")
def verify_offer(offer_id: UUID, body: FinancingVerifyIn, admin: Admin, s: Cfg):
    """Off-chain review only. Approval requires debtor-acknowledgement and assignment-notice evidence and does NOT list the offer:
    listing happens only when the on-chain `OfferCreated` event is verified."""
    return svc.review(admin, offer_id, body, s)


@router.post("/offers/{offer_id}/publish", response_model=PublishOut,
             summary="Returns the exact on-chain steps a role-holding wallet must send (the backend never signs)")
def publish(offer_id: UUID, user: AnyUser, s: Cfg):
    return svc.publish_plan(user, offer_id, s)


@router.post("/offers/{offer_id}/cancel", response_model=OfferOut, summary="Cancel a not-yet-registered request")
def cancel(offer_id: UUID, user: AnyUser, s: Cfg):
    return svc.cancel(user, offer_id, s)


@router.post("/verify-transaction", response_model=TxVerificationOut,
             summary="Verify a financing tx hash on-chain; state changes only from verified contract events")
def verify_tx(body: VerifyTxIn, user: AnyUser, s: Cfg):
    return svc.verify_tx(user, body.tx_hash, s)


@router.get("/investments", response_model=Page[InvestmentOut], summary="Investments (investor: mine; merchant: on my invoices; admin: all)")
def investments(user: AnyUser, pg: Pagination, s: Cfg):
    rows, total = svc.list_investments(user, pg, s)
    return Page(items=rows, page=pg.page, page_size=pg.page_size, total=total)


@router.get("/investments/{investment_id}", response_model=InvestmentOut, summary="One investment")
def investment(investment_id: UUID, user: AnyUser, s: Cfg):
    return svc.get_investment(user, investment_id, s)


@router.get("/settlements", response_model=Page[InvestmentOut], summary="Settled investments")
def settlements(user: AnyUser, pg: Pagination, s: Cfg):
    rows, total = svc.list_investments(user, pg, s, settled_only=True)
    return Page(items=rows, page=pg.page, page_size=pg.page_size, total=total)


@router.get("/invoices/{invoice_id}", response_model=OfferOut, summary="Financing offer of an invoice")
def by_invoice(invoice_id: UUID, user: AnyUser, s: Cfg):
    return svc.offer_for_invoice(user, invoice_id, s)
