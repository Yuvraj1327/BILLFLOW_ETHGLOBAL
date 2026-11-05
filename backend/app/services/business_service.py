"""Business profile, members and customers."""
from __future__ import annotations

import psycopg.errors

from app.core.database import transaction
from app.core.dependencies import BusinessCtx, CurrentUser, PageParams
from app.core.exceptions import conflict, forbidden, not_found
from app.repositories import businesses as repo
from app.repositories import profiles as prof
from app.repositories.system import audit, notify
from app.services._common import ACTIVE_FINANCING
from app.utils.validators import norm_address


def create(user: CurrentUser, body) -> dict:
    with transaction() as c:
        if repo.business_of_user(c, user.id):
            raise conflict("business_exists", "You already belong to a business")
        wallet = norm_address(body.payout_wallet, "payout_wallet") if body.payout_wallet else None
        b = repo.create_business(c, user.id, {**body.model_dump(), "payout_wallet": wallet})
        audit(c, user.id, "business_created", "business", b["id"])
    return b


def get(ctx: BusinessCtx) -> dict:
    with transaction() as c:
        return repo.get_business(c, ctx.business_id)


def update(ctx: BusinessCtx, body) -> dict:
    ch = body.model_dump(exclude_unset=True)
    if ctx.member_role != "owner":
        raise forbidden("Only the business owner can edit it", "owner_required")
    if "payout_wallet" in ch and ch["payout_wallet"]:
        ch["payout_wallet"] = norm_address(ch["payout_wallet"], "payout_wallet")
    with transaction() as c:
        cur = repo.get_business(c, ctx.business_id)
        if "payout_wallet" in ch and ch["payout_wallet"] != cur["payout_wallet"]:
            # Payments are bound to the payout wallet at quote time and re-checked when the chain event is applied.
            # Changing it while invoices are open would make already-correct payments unmatchable.
            open_ = c.execute("""select 1 from invoices i where i.business_id=%s and (i.status in ('PENDING','PARTIALLY_PAID','OVERDUE')
                                 or exists (select 1 from financing_offers f where f.invoice_id=i.id and f.status = any(%s::financing_status[])))
                                 limit 1""", (ctx.business_id, list(ACTIVE_FINANCING))).fetchone()
            if open_:
                raise conflict("open_invoices", "Cannot change the payout wallet while invoices are open or financed")
            audit(c, ctx.user.id, "payout_wallet_changed", "business", ctx.business_id,
                  {"old": cur["payout_wallet"], "new": ch["payout_wallet"]})
        if not ch:
            return cur
        return repo.update_business(c, ctx.business_id, ch)


def members(ctx: BusinessCtx) -> list[dict]:
    with transaction() as c:
        return repo.list_members(c, ctx.business_id)


def add_member(ctx: BusinessCtx, email: str) -> dict:
    if ctx.member_role != "owner":
        raise forbidden("Only the business owner can add members", "owner_required")
    with transaction() as c:
        p = prof.get_by_email(c, email)
        if p is None or p["role"] != "merchant":
            raise not_found("Merchant user with that email", "user_not_found")
        if (other := repo.business_of_user(c, p["id"])) and other["id"] != ctx.business_id:
            raise conflict("user_in_other_business", "That user already belongs to another business")
        repo.add_member(c, ctx.business_id, p["id"])
        audit(c, ctx.user.id, "member_added", "business", ctx.business_id, {"user_id": str(p["id"])})
        notify(c, p["id"], "added_to_business", "You were added to a business")
        return next(m for m in repo.list_members(c, ctx.business_id) if m["user_id"] == p["id"])


def remove_member(ctx: BusinessCtx, user_id) -> None:
    if ctx.member_role != "owner":
        raise forbidden("Only the business owner can remove members", "owner_required")
    with transaction() as c:
        if not repo.remove_member(c, ctx.business_id, user_id):
            raise not_found("Member", "member_not_found")
        audit(c, ctx.user.id, "member_removed", "business", ctx.business_id, {"user_id": str(user_id)})


# customers
def _cust(d: dict) -> dict:
    d = dict(d)
    if d.get("wallet_address"):
        d["wallet_address"] = norm_address(d["wallet_address"], "wallet_address")
    return d


def create_customer(ctx: BusinessCtx, body) -> dict:
    with transaction() as c:
        r = repo.create_customer(c, ctx.business_id, _cust(body.model_dump()))
        audit(c, ctx.user.id, "customer_created", "customer", r["id"])
    return r


def list_customers(ctx: BusinessCtx, q, include_archived, pg: PageParams):
    with transaction() as c:
        return repo.list_customers(c, ctx.business_id, q, include_archived, pg)


def get_customer(ctx: BusinessCtx, customer_id) -> dict:
    with transaction() as c:
        r = repo.get_customer(c, ctx.business_id, customer_id)
    if r is None:
        raise not_found("Customer", "customer_not_found")
    return r


def update_customer(ctx: BusinessCtx, customer_id, body) -> dict:
    ch = _cust(body.model_dump(exclude_unset=True))
    with transaction() as c:
        if not ch:
            r = repo.get_customer(c, ctx.business_id, customer_id)
        else:
            r = repo.update_customer(c, ctx.business_id, customer_id, ch)
            audit(c, ctx.user.id, "customer_updated", "customer", customer_id)
    if r is None:
        raise not_found("Customer", "customer_not_found")
    return r


def archive_customer(ctx: BusinessCtx, customer_id) -> None:
    with transaction() as c:
        if not repo.archive_customer(c, ctx.business_id, customer_id):
            raise not_found("Customer", "customer_not_found")
        audit(c, ctx.user.id, "customer_archived", "customer", customer_id)
