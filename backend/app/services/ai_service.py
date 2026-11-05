"""Orchestrates AI tasks around stored data. Advisory only."""
from __future__ import annotations

from datetime import date

from app.core.config import Settings
from app.core.database import transaction
from app.core.dependencies import BusinessCtx
from app.core.exceptions import not_found
from app.repositories import invoices as inv_repo
from app.repositories.system import audit
from app.services import anthropic_service as ai
from app.services import invoice_service
from app.utils.file_validation import validate_pdf


def extract(ctx: BusinessCtx, data: bytes, content_type: str | None, s: Settings) -> dict:
    pdf = validate_pdf(data, content_type, s.max_upload_bytes, max_pages=s.ai_max_pdf_pages)
    extracted = ai.extract_invoice(pdf.data)  # raises 502 on bad/invalid output; nothing persisted in that case
    with transaction() as c:
        dups = inv_repo.other_documents_with_hash(c, pdf.sha256, None)
        warnings = [f"This exact file was already uploaded for invoice {d['invoice_number'] or 'unassigned'}" for d in dups]
        if extracted.invoice_number:
            for d in inv_repo.duplicates(c, ctx.business_id, None, extracted.invoice_number, None, None, None):
                warnings.append(f"Invoice number {d['invoice_number']} already exists ({d['status']})")
        audit(c, ctx.user.id, "ai_extract_invoice", "invoice_document", None,
              {"sha256": pdf.sha256, "confidence": extracted.confidence})  # file contents are NOT logged
    return {"extracted": extracted, "sha256": pdf.sha256, "document_hash": pdf.document_hash, "pages": pdf.pages,
            "duplicate_warnings": warnings}


def _invoice_view(ctx: BusinessCtx, invoice_id, s: Settings) -> dict:
    inv = invoice_service.get(ctx.business_id, invoice_id, s)
    inv["remaining_amount"] = None
    from app.utils.validators import from_base
    inv["remaining_amount"] = from_base(int(inv["amount_base"]) - int(inv["paid_amount_base"]), inv["token_decimals"])
    return inv


def summary(ctx: BusinessCtx, invoice_id, s: Settings) -> ai.AiSummary:
    return ai.summarize(_invoice_view(ctx, invoice_id, s))


def reminder(ctx: BusinessCtx, invoice_id, tone: str, s: Settings) -> ai.AiReminder:
    return ai.draft_reminder(_invoice_view(ctx, invoice_id, s), tone)


def validate(ctx: BusinessCtx, invoice_id, s: Settings) -> dict:
    inv = _invoice_view(ctx, invoice_id, s)
    issues: list[str] = []  # deterministic checks first: they do not depend on the model
    if inv["due_date"] < inv["issue_date"]:
        issues.append("Due date is before the issue date")
    if inv["status"] in ("PENDING", "OVERDUE") and inv["due_date"] < date.today():
        issues.append("Invoice is past its due date")
    if not inv.get("description"):
        issues.append("Description is missing")
    with transaction() as c:
        dups = inv_repo.duplicates(c, ctx.business_id, invoice_id, inv["invoice_number"], None, None, None)
        dups += c.execute("select id, invoice_number, status from invoices where business_id=%s and id<>%s and customer_id=%s "
                          "and amount_base=%s and issue_date=%s", (ctx.business_id, invoice_id, inv["customer_id"],
                                                                   inv["amount_base"], inv["issue_date"])).fetchall()
    dup_msgs = sorted({f"Possible duplicate of invoice {d['invoice_number']} ({d['status']})" for d in dups})
    try:
        res = ai.validate_invoice(inv)
        return {"invoice_id": invoice_id, "issues": issues, "duplicate_warnings": dup_msgs, "ai_warnings": res.warnings,
                "confidence": res.confidence, "ai_used": True}
    except Exception:  # AI is optional here: deterministic checks still answer
        return {"invoice_id": invoice_id, "issues": issues, "duplicate_warnings": dup_msgs, "ai_warnings": [],
                "confidence": 0.0, "ai_used": False}
