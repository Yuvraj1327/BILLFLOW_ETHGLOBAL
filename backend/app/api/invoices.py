from __future__ import annotations

from typing import Annotated, Literal
from uuid import UUID

from fastapi import APIRouter, Depends, File, Query, Response, UploadFile
from pydantic import BaseModel, Field

from app.core.config import Settings, get_settings
from app.core.dependencies import MerchantBiz, Pagination
from app.core.exceptions import bad_request
from app.schemas.common import ERRORS, Page
from app.schemas.invoice import (DocumentOut, InvoiceCreate, InvoiceOut, InvoiceUpdate, PaymentLinkOut, PaymentStatusOut)
from app.services import invoice_service as svc

router = APIRouter(prefix="/invoices", tags=["Invoices"], responses=ERRORS)
Cfg = Annotated[Settings, Depends(get_settings)]
STATUS = Literal["DRAFT", "PENDING", "PARTIALLY_PAID", "PAID", "OVERDUE", "CANCELLED"]


class CancelIn(BaseModel):
    reason: str | None = Field(default=None, max_length=500)


@router.post("", response_model=InvoiceOut, status_code=201, summary="Create an invoice (DRAFT, or PENDING with issue=true)")
def create(body: InvoiceCreate, ctx: MerchantBiz, s: Cfg):
    return svc.create(ctx, body, s)


@router.get("", response_model=Page[InvoiceOut], summary="List my business's invoices")
def list_(ctx: MerchantBiz, pg: Pagination, s: Cfg, status: STATUS | None = None, customer_id: UUID | None = None,
          q: str | None = Query(None, max_length=100), sort: Literal["created_at", "due_date", "amount", "status", "invoice_number"] = "created_at",
          order: Literal["asc", "desc"] = "desc"):
    rows, total = svc.list_(ctx, status, customer_id, q, sort, order, pg, s)
    return Page(items=rows, page=pg.page, page_size=pg.page_size, total=total)


@router.get("/{invoice_id}", response_model=InvoiceOut, summary="Get an invoice")
def get(invoice_id: UUID, ctx: MerchantBiz, s: Cfg):
    return svc.get(ctx.business_id, invoice_id, s)


@router.patch("/{invoice_id}", response_model=InvoiceOut, summary="Edit a DRAFT invoice")
def update(invoice_id: UUID, body: InvoiceUpdate, ctx: MerchantBiz, s: Cfg):
    return svc.update(ctx, invoice_id, body, s)


@router.delete("/{invoice_id}", status_code=204, summary="Delete a DRAFT invoice (issued invoices must be cancelled)")
def delete(invoice_id: UUID, ctx: MerchantBiz):
    svc.delete(ctx, invoice_id)
    return Response(status_code=204)


@router.post("/{invoice_id}/issue", response_model=InvoiceOut, summary="DRAFT -> PENDING")
def issue(invoice_id: UUID, ctx: MerchantBiz, s: Cfg):
    return svc.issue_invoice(ctx, invoice_id, s)


@router.post("/{invoice_id}/cancel", response_model=InvoiceOut, summary="Cancel an unpaid, un-financed invoice")
def cancel(invoice_id: UUID, ctx: MerchantBiz, s: Cfg, body: CancelIn | None = None):
    return svc.cancel(ctx, invoice_id, body.reason if body else None, s)


@router.post("/{invoice_id}/upload", response_model=DocumentOut, status_code=201, summary="Attach the invoice PDF (private storage)")
async def upload(invoice_id: UUID, ctx: MerchantBiz, s: Cfg, file: UploadFile = File(...)):
    data = await file.read(s.max_upload_bytes + 1)
    return svc.upload_document(ctx, invoice_id, data, file.content_type, s)


@router.post("/{invoice_id}/payment-link", response_model=PaymentLinkOut, status_code=201,
             summary="Create the public checkout link (revokes the previous one)")
def payment_link(invoice_id: UUID, ctx: MerchantBiz, s: Cfg):
    return svc.create_payment_link(ctx, invoice_id, s)


@router.get("/{invoice_id}/payment-status", response_model=PaymentStatusOut, summary="Status derived from verified on-chain payments")
def payment_status(invoice_id: UUID, ctx: MerchantBiz, s: Cfg):
    return svc.payment_status(ctx.business_id, invoice_id, s)


@router.get("/{invoice_id}/documents", response_model=list[DocumentOut], summary="Documents attached to an invoice")
def documents(invoice_id: UUID, ctx: MerchantBiz):
    return svc.list_documents(ctx.business_id, invoice_id)


@router.get("/{invoice_id}/documents/{doc_id}/url", summary="60-second signed URL for a private document")
def document_url(invoice_id: UUID, doc_id: UUID, ctx: MerchantBiz):
    return svc.document_url(ctx.business_id, invoice_id, doc_id, ctx.user.id)
