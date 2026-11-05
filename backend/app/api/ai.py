from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, File, UploadFile

from app.core.config import Settings, get_settings
from app.core.dependencies import MerchantBiz
from app.schemas.ai import (ExtractionOut, InvoiceRef, ReminderIn, ReminderOut, SummaryOut, ValidationOut)
from app.schemas.common import ERRORS
from app.services import ai_service as svc

router = APIRouter(prefix="/ai", tags=["AI (advisory only)"], responses={**ERRORS, 502: {"description": "ai_upstream_error / ai_invalid_output"}})
Cfg = Annotated[Settings, Depends(get_settings)]


@router.post("/extract-invoice", response_model=ExtractionOut,
             summary="Extract invoice fields from a PDF. Nothing is saved or approved; the merchant reviews the result.")
async def extract(ctx: MerchantBiz, s: Cfg, file: UploadFile = File(...)):
    data = await file.read(s.max_upload_bytes + 1)
    return svc.extract(ctx, data, file.content_type, s)


@router.post("/invoice-summary", response_model=SummaryOut, summary="Plain-language invoice summary")
def invoice_summary(body: InvoiceRef, ctx: MerchantBiz, s: Cfg):
    return svc.summary(ctx, body.invoice_id, s)


@router.post("/payment-reminder", response_model=ReminderOut, summary="Draft a reminder (never sent automatically)")
def payment_reminder(body: ReminderIn, ctx: MerchantBiz, s: Cfg):
    return svc.reminder(ctx, body.invoice_id, body.tone, s)


@router.post("/validate-invoice", response_model=ValidationOut, summary="Deterministic checks + AI warnings; advisory only")
def validate_invoice(body: InvoiceRef, ctx: MerchantBiz, s: Cfg):
    return svc.validate(ctx, body.invoice_id, s)
