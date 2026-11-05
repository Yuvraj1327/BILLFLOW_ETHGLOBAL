"""Invoice lifecycle (off-chain). PAID / PARTIALLY_PAID can never be set here - only verified chain events do that."""
from __future__ import annotations

import logging
from datetime import date
from uuid import UUID, uuid4

import psycopg.errors

from app.core.config import Settings
from app.core.database import transaction
from app.core.dependencies import BusinessCtx, PageParams
from app.core.exceptions import bad_request, conflict, forbidden, not_found
from app.core.security import new_opaque_token
from app.models.enums import can_invoice_transition
from app.repositories import businesses as biz_repo
from app.repositories import invoices as repo
from app.repositories import payments as pay_repo
from app.repositories.system import audit
from app.services._common import ACTIVE_FINANCING, decimals, explorer_tx, money
from app.services.supabase_client import get_storage
from app.utils.file_validation import validate_pdf
from app.utils.validators import canonical_invoice_hash, onchain_invoice_id, to_base

log = logging.getLogger("billflow.invoices")
PAYABLE_STATUSES = ("PENDING", "PARTIALLY_PAID", "OVERDUE")


def serialize(r: dict, s: Settings) -> dict:
    d = r["token_decimals"]
    return {
        "id": r["id"], "merchant_id": r["business_id"], "customer_id": r["customer_id"], "customer_name": r.get("customer_name"),
        "invoice_number": r["invoice_number"], "description": r["description"], "amount": money(r["amount_base"], d),
        "amount_base": str(int(r["amount_base"])), "token_decimals": d, "currency": r["currency"],
        "issue_date": r["issue_date"], "due_date": r["due_date"], "status": r["status"],
        "paid_amount": money(r["paid_amount_base"], d), "paid_amount_base": str(int(r["paid_amount_base"])),
        "review_status": r["review_status"], "onchain_invoice_id": r["onchain_invoice_id"], "invoice_hash": r["invoice_hash"],
        "document_hash": ("0x" + r["document_sha256"]) if r.get("document_sha256") else None,
        "payment_tx_hash": r["paid_tx_hash"], "payment_explorer_url": explorer_tx(s, r["paid_tx_hash"]),
        "financing_status": r.get("financing_status"), "financing_offer_id": r.get("financing_offer_id"),
        "created_at": r["created_at"], "updated_at": r["updated_at"],
    }


def payable(inv: dict, payout_wallet: str | None) -> tuple[bool, str | None]:
    """Whether a payer may currently settle this invoice directly via BillFlowPayments."""
    if inv["status"] not in PAYABLE_STATUSES:
        return False, f"Invoice is {inv['status']}"
    if inv.get("financing_status") in ACTIVE_FINANCING:
        return False, "Invoice has been submitted for financing; the debtor repays through the financing flow"
    if not payout_wallet:
        return False, "Merchant has not configured a payout wallet"
    if not inv.get("invoice_hash") or not inv.get("onchain_invoice_id"):
        return False, "Invoice has no on-chain reference"
    return True, None


def _hashes(inv_id, business_id, customer_id, number, amount_base, dec, issue, due) -> dict:
    return {"onchain_invoice_id": onchain_invoice_id(inv_id),
            "invoice_hash": canonical_invoice_hash(invoice_id=inv_id, business_id=business_id, customer_id=customer_id,
                                                   invoice_number=number, amount_base=amount_base, token_decimals=dec,
                                                   currency="USDT", issue_date=issue, due_date=due)}


def _amount(body, dec: int) -> int | None:
    if getattr(body, "amount_base", None) is not None:
        if not str(body.amount_base).isdigit() or int(body.amount_base) <= 0:
            raise bad_request("invalid_amount", "amount_base must be a positive integer")
        return int(body.amount_base)
    if getattr(body, "amount", None) is not None:
        return to_base(body.amount, dec)
    return None


def create(ctx: BusinessCtx, body, s: Settings) -> dict:
    dec = decimals(s)
    amount = _amount(body, dec)
    issue = body.issue_date or date.today()
    if body.due_date < issue:
        raise bad_request("invalid_dates", "due_date cannot be before issue_date")
    inv_id = uuid4()
    try:
        with transaction() as c:
            cust = biz_repo.get_customer(c, ctx.business_id, body.customer_id)
            if cust is None or cust.get("archived_at"):
                raise not_found("Customer", "customer_not_found")
            row = {"id": inv_id, "business_id": ctx.business_id, "customer_id": body.customer_id, "invoice_number": body.invoice_number,
                   "description": body.description, "amount_base": amount, "token_decimals": dec, "currency": "USDT",
                   "issue_date": issue, "due_date": body.due_date, "created_by": ctx.user.id,
                   **_hashes(inv_id, ctx.business_id, body.customer_id, body.invoice_number, amount, dec, issue, body.due_date)}
            repo.insert(c, row)
            audit(c, ctx.user.id, "invoice_created", "invoice", inv_id, {"number": body.invoice_number})
            out = repo.get(c, inv_id)
    except psycopg.errors.UniqueViolation as e:
        raise conflict("duplicate_invoice_number", "An invoice with this number already exists for your business") from e
    if body.issue:
        return issue_invoice(ctx, inv_id, s)
    return serialize(out, s)


def get(ctx_business_id, invoice_id, s: Settings) -> dict:
    with transaction() as c:
        r = repo.get(c, invoice_id, ctx_business_id)
    if r is None:  # same response for "missing" and "someone else's": no existence oracle across businesses
        raise not_found("Invoice", "invoice_not_found")
    return serialize(r, s)


def list_(ctx: BusinessCtx, status, customer_id, q, sort, order, pg: PageParams, s: Settings):
    with transaction() as c:
        rows, total = repo.list_(c, ctx.business_id, status, customer_id, q, sort, order, pg)
    return [serialize(r, s) for r in rows], total


def update(ctx: BusinessCtx, invoice_id, body, s: Settings) -> dict:
    changes = body.model_dump(exclude_unset=True)
    try:
        with transaction() as c:
            cur = repo.get(c, invoice_id, ctx.business_id, lock=True)
            if cur is None:
                raise not_found("Invoice", "invoice_not_found")
            if cur["status"] != "DRAFT":
                raise conflict("invoice_not_editable", f"Only DRAFT invoices can be edited (this one is {cur['status']})")
            upd: dict = {}
            if "customer_id" in changes and changes["customer_id"]:
                cust = biz_repo.get_customer(c, ctx.business_id, changes["customer_id"])
                if cust is None or cust.get("archived_at"):
                    raise not_found("Customer", "customer_not_found")
                upd["customer_id"] = changes["customer_id"]
            for k in ("invoice_number", "description", "issue_date", "due_date"):
                if k in changes and changes[k] is not None:
                    upd[k] = changes[k]
            amt = _amount(body, cur["token_decimals"])
            if amt is not None:
                upd["amount_base"] = amt
            merged = {**cur, **upd}
            if merged["due_date"] < merged["issue_date"]:
                raise bad_request("invalid_dates", "due_date cannot be before issue_date")
            if upd:
                upd.update(_hashes(cur["id"], cur["business_id"], merged["customer_id"], merged["invoice_number"],
                                   merged["amount_base"], cur["token_decimals"], merged["issue_date"], merged["due_date"]))
                repo.update(c, invoice_id, upd)
                audit(c, ctx.user.id, "invoice_updated", "invoice", invoice_id, {"fields": sorted(changes)})
            out = repo.get(c, invoice_id)
    except psycopg.errors.UniqueViolation as e:
        raise conflict("duplicate_invoice_number", "An invoice with this number already exists for your business") from e
    return serialize(out, s)


def issue_invoice(ctx: BusinessCtx, invoice_id, s: Settings) -> dict:
    with transaction() as c:
        cur = repo.get(c, invoice_id, ctx.business_id, lock=True)
        if cur is None:
            raise not_found("Invoice", "invoice_not_found")
        if not can_invoice_transition(cur["status"], "PENDING"):
            raise conflict("invalid_transition", f"Cannot issue an invoice that is {cur['status']}")
        biz = biz_repo.get_business(c, ctx.business_id)
        if not biz["payout_wallet"]:
            raise bad_request("no_payout_wallet", "Set a payout wallet on your business before issuing invoices")
        repo.update(c, invoice_id, {"status": "PENDING"})
        audit(c, ctx.user.id, "invoice_issued", "invoice", invoice_id)
        out = repo.get(c, invoice_id)
    return serialize(out, s)


def cancel(ctx: BusinessCtx, invoice_id, reason: str | None, s: Settings) -> dict:
    with transaction() as c:
        cur = repo.get(c, invoice_id, ctx.business_id, lock=True)
        if cur is None:
            raise not_found("Invoice", "invoice_not_found")
        if not can_invoice_transition(cur["status"], "CANCELLED"):
            raise conflict("invalid_transition", f"Cannot cancel an invoice that is {cur['status']}")
        if int(cur["paid_amount_base"]) > 0:
            raise conflict("invoice_has_payments", "An invoice with payments cannot be cancelled")
        if cur.get("financing_status") in ACTIVE_FINANCING:
            raise conflict("invoice_financed", "Cancel the financing request first")
        repo.update(c, invoice_id, {"status": "CANCELLED", "cancel_reason": reason})
        c.execute("update invoices set cancelled_at=now() where id=%s", (invoice_id,))
        repo.revoke_links(c, invoice_id)
        audit(c, ctx.user.id, "invoice_cancelled", "invoice", invoice_id, {"reason": reason})
        out = repo.get(c, invoice_id)
    return serialize(out, s)


def delete(ctx: BusinessCtx, invoice_id) -> None:
    with transaction() as c:
        cur = repo.get(c, invoice_id, ctx.business_id, lock=True)
        if cur is None:
            raise not_found("Invoice", "invoice_not_found")
        if cur["status"] != "DRAFT":
            raise conflict("invoice_not_deletable", "Only DRAFT invoices can be deleted; cancel issued invoices instead")
        docs = repo.list_documents(c, invoice_id)
        repo.delete(c, invoice_id)
        audit(c, ctx.user.id, "invoice_deleted", "invoice", invoice_id, {"number": cur["invoice_number"]})
    for d in docs:  # best-effort storage cleanup after the DB commit
        try:
            get_storage().remove(d["storage_path"])
        except Exception:  # noqa: BLE001
            log.warning("storage cleanup failed for %s", d["storage_path"])


def upload_document(ctx: BusinessCtx, invoice_id, data: bytes, content_type: str | None, s: Settings) -> dict:
    with transaction() as c:
        cur = repo.get(c, invoice_id, ctx.business_id)
        if cur is None:
            raise not_found("Invoice", "invoice_not_found")
        if cur["status"] in ("CANCELLED", "PAID"):
            raise conflict("invoice_not_editable", f"Cannot attach documents to a {cur['status']} invoice")
    pdf = validate_pdf(data, content_type, s.max_upload_bytes, max_pages=50)
    path = f"{ctx.business_id}/{invoice_id}/{pdf.sha256}.pdf"
    get_storage().upload(path, pdf.data, "application/pdf")
    try:
        with transaction() as c:
            doc = repo.add_document(c, {"invoice_id": invoice_id, "business_id": ctx.business_id, "storage_path": path,
                                        "sha256": pdf.sha256, "mime_type": "application/pdf", "size_bytes": pdf.size,
                                        "uploaded_by": ctx.user.id})
            dups = repo.other_documents_with_hash(c, pdf.sha256, invoice_id)
            audit(c, ctx.user.id, "invoice_document_uploaded", "invoice", invoice_id, {"sha256": pdf.sha256})
    except psycopg.errors.UniqueViolation as e:
        raise conflict("document_exists", "This exact file is already attached to the invoice") from e
    warnings = [f"Same file already used on invoice {d['invoice_number'] or 'unassigned'}" for d in dups]
    return {"id": doc["id"], "invoice_id": invoice_id, "sha256": pdf.sha256, "document_hash": pdf.document_hash,
            "size_bytes": pdf.size, "mime_type": "application/pdf", "created_at": doc["created_at"], "duplicate_warnings": warnings}


def create_payment_link(ctx: BusinessCtx, invoice_id, s: Settings) -> dict:
    with transaction() as c:
        cur = repo.get(c, invoice_id, ctx.business_id, lock=True)
        if cur is None:
            raise not_found("Invoice", "invoice_not_found")
        biz = biz_repo.get_business(c, ctx.business_id)
        ok, why = payable(cur, biz["payout_wallet"])
        if not ok:
            raise conflict("invoice_not_payable", why or "Invoice is not payable")
        repo.revoke_links(c, invoice_id)  # one active link at a time; old ones stop working
        link = repo.create_link(c, invoice_id, new_opaque_token(32), s.payment_link_ttl_days)
        audit(c, ctx.user.id, "payment_link_created", "invoice", invoice_id)
    return {"id": link["id"], "token": link["token"], "url": f"{s.public_checkout_base_url.rstrip('/')}/pay/{link['token']}",
            "expires_at": link["expires_at"]}


def payment_status(ctx_business_id, invoice_id, s: Settings) -> dict:
    with transaction() as c:
        inv = repo.get(c, invoice_id, ctx_business_id)
        if inv is None:
            raise not_found("Invoice", "invoice_not_found")
        biz = biz_repo.get_business(c, inv["business_id"])
        pays = pay_repo.for_invoice(c, invoice_id)
    return status_view(inv, biz["payout_wallet"], pays, s)


def status_view(inv: dict, payout_wallet, pays: list[dict], s: Settings) -> dict:
    d = inv["token_decimals"]
    ok, why = payable(inv, payout_wallet)
    return {"invoice_id": inv["id"], "status": inv["status"], "amount": money(inv["amount_base"], d),
            "paid_amount": money(inv["paid_amount_base"], d),
            "remaining_amount": money(int(inv["amount_base"]) - int(inv["paid_amount_base"]), d),
            "payments": [{"id": p["id"], "payer_wallet": p["payer_wallet"], "amount": money(p["amount_base"], d),
                          "amount_base": str(int(p["amount_base"])), "tx_hash": p["tx_hash"],
                          "explorer_url": explorer_tx(s, p["tx_hash"]), "status": p["status"], "confirmed_at": p["confirmed_at"]}
                         for p in pays],
            "financing_status": inv.get("financing_status"), "payable": ok, "payable_reason": why}


def list_documents(business_id, invoice_id) -> list[dict]:
    """business_id=None means an admin reading any invoice."""
    with transaction() as c:
        inv = repo.get(c, invoice_id, business_id)
        if inv is None:
            raise not_found("Invoice", "invoice_not_found")
        docs = repo.list_documents(c, invoice_id)
    return [{"id": d["id"], "invoice_id": invoice_id, "sha256": d["sha256"], "document_hash": "0x" + d["sha256"],
             "size_bytes": d["size_bytes"], "mime_type": d["mime_type"], "created_at": d["created_at"], "duplicate_warnings": []}
            for d in docs]


def document_url(business_id, invoice_id, doc_id, actor_id, expires_in: int = 60) -> dict:
    """Short-lived signed URL for a private-bucket object, issued only after the ownership check above."""
    with transaction() as c:
        inv = repo.get(c, invoice_id, business_id)
        if inv is None:
            raise not_found("Invoice", "invoice_not_found")
        doc = next((d for d in repo.list_documents(c, invoice_id) if str(d["id"]) == str(doc_id)), None)
        if doc is None:
            raise not_found("Document", "document_not_found")
        audit(c, actor_id, "document_url_issued", "invoice_document", doc_id)
    from datetime import datetime, timedelta, timezone
    return {"url": get_storage().signed_url(doc["storage_path"], expires_in),
            "expires_at": datetime.now(timezone.utc) + timedelta(seconds=expires_in)}
