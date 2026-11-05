from __future__ import annotations

from typing import Annotated, Any, Literal
from uuid import UUID

from fastapi import APIRouter, Depends, Query
from pydantic import BaseModel, Field

from app.core.config import Settings, get_settings
from app.core.database import transaction
from app.core.dependencies import Admin, Pagination
from app.core.exceptions import bad_request, conflict, not_found
from app.repositories import businesses as biz_repo
from app.repositories import chain as chain_repo
from app.repositories import invoices as inv_repo
from app.repositories import profiles as prof
from app.repositories import system as sysrepo
from app.schemas.business import BusinessOut
from app.schemas.common import ERRORS, Page, Strict
from app.schemas.user import ProfileOut, RoleUpdate
from app.services.event_processor import retry_unprocessed

router = APIRouter(prefix="/admin", tags=["Admin"], responses=ERRORS)
Cfg = Annotated[Settings, Depends(get_settings)]


class Decision(Strict):
    decision: Literal["verify", "reject"]
    notes: str | None = Field(default=None, max_length=1000)


class SettingIn(Strict):
    value: Any


def _page(rows, total, pg):
    return {"items": rows, "page": pg.page, "page_size": pg.page_size, "total": total}


@router.get("/users", summary="List users")
def users(admin: Admin, pg: Pagination, role: Literal["merchant", "customer", "investor", "admin"] | None = None,
          q: str | None = Query(None, max_length=100)):
    with transaction() as c:
        rows, total = prof.list_users(c, role, q, pg.page_size, pg.offset)
    return _page(rows, total, pg)


@router.patch("/users/{user_id}/role", response_model=ProfileOut, summary="Change a user's role (the ONLY way to create an admin)")
def set_role(user_id: UUID, body: RoleUpdate, admin: Admin):
    if user_id == admin.id:
        raise conflict("cannot_change_own_role", "Admins cannot change their own role")
    with transaction() as c:
        r = prof.set_role(c, user_id, body.role)
        if r is None:
            raise not_found("User", "user_not_found")
        sysrepo.audit(c, admin.id, "role_changed", "profile", user_id, {"role": body.role})
    return r


@router.patch("/users/{user_id}/investor-verification", response_model=ProfileOut, summary="Verify or reject an investor (off-chain record)")
def investor_verification(user_id: UUID, body: Decision, admin: Admin):
    status = "verified" if body.decision == "verify" else "rejected"
    with transaction() as c:
        p = prof.get(c, user_id)
        if p is None or p["role"] != "investor":
            raise not_found("Investor", "investor_not_found")
        r = prof.set_investor_verification(c, user_id, status)
        sysrepo.audit(c, admin.id, f"investor_{status}", "profile", user_id, {"notes": body.notes})
        sysrepo.notify(c, user_id, f"investor_{status}", f"Investor profile {status}", body.notes)
    return r


@router.get("/businesses", response_model=Page[BusinessOut], summary="List businesses")
def businesses(admin: Admin, pg: Pagination, status: Literal["unverified", "pending", "verified", "rejected"] | None = None):
    with transaction() as c:
        rows, total = biz_repo.list_businesses(c, status, pg)
    return Page(items=rows, page=pg.page, page_size=pg.page_size, total=total)


@router.post("/businesses/{business_id}/review", response_model=BusinessOut, summary="Verify or reject a business")
def review_business(business_id: UUID, body: Decision, admin: Admin):
    status = "verified" if body.decision == "verify" else "rejected"
    with transaction() as c:
        b = biz_repo.get_business(c, business_id)
        if b is None:
            raise not_found("Business", "business_not_found")
        if status == "verified" and not b["payout_wallet"]:
            raise bad_request("no_payout_wallet", "A business needs a payout wallet before it can be verified")
        r = biz_repo.set_business_verification(c, business_id, status, admin.id)
        sysrepo.audit(c, admin.id, f"business_{status}", "business", business_id, {"notes": body.notes})
        sysrepo.notify_business(c, business_id, f"business_{status}", f"Your business was {status}", body.notes)
    return r


@router.post("/invoices/{invoice_id}/review", summary="Mark an invoice verified/flagged (off-chain advisory record)")
def review_invoice(invoice_id: UUID, body: Decision, admin: Admin):
    status = "verified" if body.decision == "verify" else "rejected"
    with transaction() as c:
        inv = inv_repo.get(c, invoice_id, lock=True)
        if inv is None:
            raise not_found("Invoice", "invoice_not_found")
        inv_repo.update(c, invoice_id, {"review_status": status})  # never touches payment/financing status
        sysrepo.audit(c, admin.id, f"invoice_review_{status}", "invoice", invoice_id, {"notes": body.notes})
    return {"invoice_id": invoice_id, "review_status": status}


@router.get("/invoices/{invoice_id}/documents", summary="Admin: documents of any invoice (financing review)")
def admin_documents(invoice_id: UUID, admin: Admin):
    from app.services import invoice_service
    return invoice_service.list_documents(None, invoice_id)


@router.get("/invoices/{invoice_id}/documents/{doc_id}/url", summary="Admin: 60-second signed URL for a document")
def admin_document_url(invoice_id: UUID, doc_id: UUID, admin: Admin):
    from app.services import invoice_service
    return invoice_service.document_url(None, invoice_id, doc_id, admin.id)


@router.get("/transactions", summary="Tracked blockchain transactions")
def transactions(admin: Admin, pg: Pagination, status: Literal["SUBMITTED", "CONFIRMED", "FAILED"] | None = None):
    with transaction() as c:
        w, p = ("true", []) if not status else ("status=%s::tx_status", [status])
        total = c.execute(f"select count(*) n from blockchain_transactions where {w}", p).fetchone()["n"]
        rows = c.execute(f"select * from blockchain_transactions where {w} order by created_at desc limit %s offset %s",
                         p + [pg.page_size, pg.offset]).fetchall()
    return _page(rows, total, pg)


@router.get("/events", summary="Indexed contract events (processed or not)")
def events(admin: Admin, pg: Pagination, unprocessed_only: bool = False, event_name: str | None = Query(None, max_length=60)):
    w, p = ["true"], []
    if unprocessed_only:
        w.append("processed_at is null")
    if event_name:
        w.append("event_name=%s"); p.append(event_name)
    ws = " and ".join(w)
    with transaction() as c:
        total = c.execute(f"select count(*) n from blockchain_events where {ws}", p).fetchone()["n"]
        rows = c.execute(f"select * from blockchain_events where {ws} order by block_number desc, log_index desc limit %s offset %s",
                         p + [pg.page_size, pg.offset]).fetchall()
    return _page(rows, total, pg)


@router.get("/audit-logs", summary="Audit log")
def audit_logs(admin: Admin, pg: Pagination, action: str | None = Query(None, max_length=80), entity_type: str | None = Query(None, max_length=60)):
    w, p = ["true"], []
    if action:
        w.append("action=%s"); p.append(action)
    if entity_type:
        w.append("entity_type=%s"); p.append(entity_type)
    ws = " and ".join(w)
    with transaction() as c:
        total = c.execute(f"select count(*) n from audit_logs where {ws}", p).fetchone()["n"]
        rows = c.execute(f"select * from audit_logs where {ws} order by id desc limit %s offset %s", p + [pg.page_size, pg.offset]).fetchall()
    return _page(rows, total, pg)


@router.get("/settings", summary="Platform settings")
def settings_list(admin: Admin):
    with transaction() as c:
        return sysrepo.list_settings(c)


@router.put("/settings/{key}", summary="Change a platform setting")
def settings_put(key: Annotated[str, Field(pattern=r"^[a-z0-9_]{1,60}$")], body: SettingIn, admin: Admin):
    if key == "max_discount_bps" and not (isinstance(body.value, int) and 0 <= body.value <= 10000):
        raise bad_request("invalid_setting", "max_discount_bps must be an integer between 0 and 10000")
    with transaction() as c:
        sysrepo.set_setting(c, key, body.value, admin.id)
        sysrepo.audit(c, admin.id, "setting_changed", "platform_setting", key, {"value": body.value})
    return {"key": key, "value": body.value}


@router.get("/indexer", summary="Indexer status")
def indexer(admin: Admin, s: Cfg):
    with transaction() as c:
        cursor = chain_repo.get_last_block(c, s.whitechain_chain_id, "billflow:combined")
        pend = c.execute("select count(*) n from blockchain_events where processed_at is null and reorged_at is null").fetchone()["n"]
        reorg = c.execute("select count(*) n from blockchain_events where reorged_at is not null").fetchone()["n"]
    return {"enabled_in_api_process": s.indexer_enabled, "cursor_block": cursor, "unprocessed_events": pend, "reorged_events": reorg,
            "run_separately": "python -m app.workers.blockchain_indexer"}


@router.post("/indexer/retry", summary="Retry parked (unprocessed) events now")
def indexer_retry(admin: Admin, s: Cfg):
    return {"applied": retry_unprocessed(s)}
