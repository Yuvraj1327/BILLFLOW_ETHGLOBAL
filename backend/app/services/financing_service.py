"""Invoice-financing workflow (off-chain part). On-chain state (LISTED/FUNDED/SETTLED...) only ever comes from
verified events (see event_processor). Nothing here signs or submits a transaction, or custodies keys."""
from __future__ import annotations

import logging
from datetime import date, datetime, time, timedelta, timezone

import psycopg.errors

from app.core.config import Settings
from app.core.database import transaction
from app.core.dependencies import BusinessCtx, CurrentUser, PageParams
from app.core.exceptions import bad_request, conflict, forbidden, not_found, unavailable
from app.models.enums import FINANCING_DISPLAY, can_financing_transition
from app.repositories import businesses as biz_repo
from app.repositories import financing as repo
from app.repositories import invoices as inv_repo
from app.repositories.system import audit, get_setting, notify_admins, notify_business
from app.services._common import explorer_tx, money
from app.services.blockchain_service import get_blockchain
from app.services.event_processor import verify_transaction
from app.utils.validators import ZERO_ADDRESS, hash_json, norm_address, to_base

log = logging.getLogger("billflow.financing")
INVESTOR_VISIBLE = ("LISTED", "FUNDED", "SETTLED", "DEFAULTED", "EXPIRED")
DISCLOSURE = ("Testnet demo. Invoice financing carries credit risk: the debtor may not repay. The discount is not a guaranteed "
              "return, and AI extraction or platform review is not a legal verification of the underlying invoice.")


def _unix(d: date) -> int:
    return int(datetime.combine(d, time.min, tzinfo=timezone.utc).timestamp())


def serialize_offer(r: dict, s: Settings, role: str = "admin") -> dict:
    d = r["token_decimals"]
    face, adv = int(r["face_value_base"]), int(r["advance_base"])
    status = r["status"]
    overdue = status == "DEFAULTED" or (status == "FUNDED" and r["maturity_date"] < date.today())
    out = {
        "id": r["id"], "invoice_id": r["invoice_id"], "invoice_number": r["invoice_number"], "business_id": r["business_id"],
        "business_name": r.get("business_name"), "business_verified": r.get("business_verification") == "verified",
        "status": status, "display_status": "OVERDUE" if overdue else FINANCING_DISPLAY.get(status, status), "is_overdue": overdue,
        "face_value": money(face, d), "face_value_base": str(face), "advance": money(adv, d), "advance_base": str(adv),
        "discount_bps": ((face - adv) * 10000) // face, "token_decimals": d, "maturity_date": r["maturity_date"],
        "funding_deadline": r["funding_deadline"],
        "onchain_offer_id": str(int(r["onchain_offer_id"])) if r["onchain_offer_id"] is not None else None,
        "onchain_registered_at": r.get("onchain_registered_at"), "onchain_verified_at": r.get("onchain_verified_at"),
        "contract_address": s.whitechain_financing_contract or None,
        "debtor_ack": None, "assignment_notice": None, "review_notes": None, "created_at": r["created_at"], "disclosure": DISCLOSURE,
    }
    if role in ("admin", "merchant"):  # investors see the on-chain facts only, not review evidence
        out["debtor_ack"] = r.get("debtor_ack")
        out["assignment_notice"] = r.get("assignment_notice")
        out["review_notes"] = r.get("review_notes")
    return out


def _biz_of(user: CurrentUser) -> str | None:
    with transaction() as c:
        b = biz_repo.business_of_user(c, user.id)
    return b["id"] if b else None


def _check_view(user: CurrentUser, offer: dict, my_business) -> None:
    if user.role == "admin":
        return
    if user.role == "merchant" and my_business is not None and offer["business_id"] == my_business:
        return
    if user.role == "investor" and offer["status"] in INVESTOR_VISIBLE:
        return
    raise not_found("Financing offer", "offer_not_found")  # no existence oracle


# ───────────────────────── submit ─────────────────────────
def submit(ctx: BusinessCtx, body, s: Settings) -> dict:
    with transaction() as c:
        inv = inv_repo.get(c, body.invoice_id, ctx.business_id, lock=True)
        if inv is None:
            raise not_found("Invoice", "invoice_not_found")
        biz = biz_repo.get_business(c, ctx.business_id)
        if biz["verification_status"] != "verified":
            raise forbidden("Your business must be verified by an admin before invoices can be financed", "business_not_verified")
        if not biz["payout_wallet"]:
            raise bad_request("no_payout_wallet", "Set a payout wallet on your business first")
        if inv["status"] != "PENDING" or int(inv["paid_amount_base"]) > 0:
            raise conflict("invoice_not_financeable", f"Only unpaid PENDING invoices can be financed (this one is {inv['status']})")
        if inv["due_date"] <= date.today():
            raise conflict("invoice_not_financeable", "Invoice is already due; it cannot be financed")
        if repo.get_offer_by_invoice(c, inv["id"]):
            raise conflict("financing_exists", "A financing request already exists for this invoice")
        d = inv["token_decimals"]
        face = int(inv["amount_base"])
        adv = int(body.advance_base) if body.advance_base is not None else to_base(body.advance, d, "advance")
        if adv <= 0 or adv >= face:
            raise bad_request("invalid_advance", "Advance must be greater than zero and less than the invoice face value")
        max_bps = int(get_setting(c, "max_discount_bps", 2000))
        if (face - adv) * 10000 > face * max_bps:  # exact integer comparison, no rounding
            raise bad_request("discount_too_high", f"Discount exceeds the platform maximum of {max_bps} bps", max_discount_bps=max_bps)
        cust = biz_repo.get_customer(c, ctx.business_id, inv["customer_id"])
        wallet = body.debtor_wallet or cust["wallet_address"]
        wallet = norm_address(wallet, "debtor_wallet") if wallet else None
        window = body.funding_window_hours or 72
        offer = repo.insert_offer(c, {
            "invoice_id": inv["id"], "business_id": ctx.business_id, "face_value_base": face, "advance_base": adv,
            "maturity_date": inv["due_date"], "funding_deadline": datetime.now(timezone.utc) + timedelta(hours=window),
            "debtor_name": cust["name"], "debtor_wallet": wallet,
            "debtor_ref": hash_json({"customer_id": str(cust["id"]), "name": cust["name"]}),
        })
        inv_repo.update(c, inv["id"], {"review_status": "pending"})
        audit(c, ctx.user.id, "financing_submitted", "financing_offer", offer["id"], {"invoice_id": str(inv["id"]), "advance_base": str(adv)})
        notify_admins(c, "financing_submitted", "New financing request", f"Invoice {inv['invoice_number']} awaits review.")
        out = repo.get_offer(c, offer["id"])
    return serialize_offer(out, s, "merchant")


# ───────────────────────── read ─────────────────────────
def list_offers(user: CurrentUser, status: str | None, pg: PageParams, s: Settings):
    mine, statuses = None, ([status] if status else None)
    if user.role == "merchant":
        mine = _biz_of(user)
        if mine is None:
            return [], 0
    elif user.role == "investor":
        if status and status not in INVESTOR_VISIBLE:
            return [], 0
        statuses = [status] if status else ["LISTED"]
    elif user.role != "admin":
        raise forbidden()
    with transaction() as c:
        rows, total = repo.list_offers(c, business_id=mine, statuses=statuses, pg=pg)
    return [serialize_offer(r, s, user.role) for r in rows], total


def get_offer(user: CurrentUser, offer_id, s: Settings) -> dict:
    with transaction() as c:
        r = repo.get_offer(c, offer_id)
    if r is None:
        raise not_found("Financing offer", "offer_not_found")
    _check_view(user, r, _biz_of(user) if user.role == "merchant" else None)
    return serialize_offer(r, s, user.role)


def offer_for_invoice(user: CurrentUser, invoice_id, s: Settings) -> dict:
    with transaction() as c:
        r = repo.get_offer_by_invoice(c, invoice_id)
    if r is None:
        raise not_found("Financing offer", "offer_not_found")
    _check_view(user, r, _biz_of(user) if user.role == "merchant" else None)
    return serialize_offer(r, s, user.role)


# ───────────────────────── admin review ─────────────────────────
def review(admin: CurrentUser, offer_id, body, s: Settings) -> dict:
    with transaction() as c:
        o = repo.get_offer(c, offer_id, lock=True)
        if o is None:
            raise not_found("Financing offer", "offer_not_found")
        target = {"start_review": "UNDER_REVIEW", "approve": "APPROVED", "reject": "REJECTED"}[body.decision]
        if not can_financing_transition(o["status"], target):
            raise conflict("invalid_transition", f"Cannot go from {o['status']} to {target}")
        upd: dict = {"status": target, "reviewed_by": admin.id, "reviewed_at": datetime.now(timezone.utc)}
        if body.notes:
            upd["review_notes"] = body.notes
        if body.decision == "reject":
            if not body.notes:
                raise bad_request("notes_required", "A rejection must include notes")
            inv_repo.update(c, o["invoice_id"], {"review_status": "rejected"})
        if body.decision == "approve":
            if o["business_verification"] != "verified":
                raise conflict("business_not_verified", "The business is no longer verified")
            ack = body.debtor_ack.model_dump(mode="json") if body.debtor_ack else o.get("debtor_ack")
            notice = body.assignment_notice.model_dump(mode="json") if body.assignment_notice else o.get("assignment_notice")
            if not ack or not notice:
                raise bad_request("evidence_required", "Approval needs both debtor-acknowledgement and assignment-notice evidence")
            upd.update({"debtor_ack": ack, "assignment_notice": notice, "debtor_ack_hash": hash_json(ack),
                        "debtor_ack_at": body.debtor_ack.acknowledged_at if body.debtor_ack else o.get("debtor_ack_at")})
            inv_repo.update(c, o["invoice_id"], {"review_status": "verified"})
        repo.update_offer(c, offer_id, upd)
        audit(c, admin.id, f"financing_{body.decision}", "financing_offer", offer_id, {"notes": body.notes})
        notify_business(c, o["business_id"], f"financing_{target.lower()}", f"Financing request {target.replace('_', ' ').lower()}",
                        f"Invoice {o['invoice_number']}")
        out = repo.get_offer(c, offer_id)
    return serialize_offer(out, s, "admin")


def cancel(user: CurrentUser, offer_id, s: Settings) -> dict:
    mine = _biz_of(user) if user.role == "merchant" else None
    with transaction() as c:
        o = repo.get_offer(c, offer_id, lock=True)
        if o is None or (user.role == "merchant" and o["business_id"] != mine) or user.role not in ("merchant", "admin"):
            raise not_found("Financing offer", "offer_not_found")
        if o["onchain_offer_id"] is not None:
            raise conflict("registered_onchain", "Already registered on-chain: cancel through the contract (cancelOffer/cancelInvoice); "
                           "the cancellation is picked up from the chain event")
        if not can_financing_transition(o["status"], "CANCELLED"):
            raise conflict("invalid_transition", f"Cannot cancel an offer that is {o['status']}")
        repo.update_offer(c, offer_id, {"status": "CANCELLED"})
        inv_repo.update(c, o["invoice_id"], {"review_status": "unverified"})
        audit(c, user.id, "financing_cancelled", "financing_offer", offer_id)
        out = repo.get_offer(c, offer_id)
    return serialize_offer(out, s, user.role)


# ───────────────────────── publish: tells the signer what to send; never sends ─────────────────────────
def publish_plan(user: CurrentUser, offer_id, s: Settings) -> dict:
    if not s.whitechain_financing_contract:
        raise unavailable("financing_not_configured", "WHITECHAIN_FINANCING_CONTRACT is not configured")
    mine = _biz_of(user) if user.role == "merchant" else None
    with transaction() as c:
        o = repo.get_offer(c, offer_id)
        if o is None or (user.role == "merchant" and o["business_id"] != mine) or user.role not in ("merchant", "admin"):
            raise not_found("Financing offer", "offer_not_found")
        if o["status"] == "LISTED":
            return {"offer_id": o["id"], "status": "LISTED", "chain_id": s.whitechain_chain_id, "next_step": None,
                    "remaining_steps": [], "message": "Already listed on-chain."}
        if o["status"] != "APPROVED":
            raise conflict("not_approved", f"Only APPROVED offers can be published (this one is {o['status']})")
        docs = inv_repo.list_documents(c, o["invoice_id"])
        inv = inv_repo.get(c, o["invoice_id"])
    if not docs:
        raise conflict("document_required", "Upload the invoice PDF first: its SHA-256 is anchored on-chain")
    contract = s.whitechain_financing_contract
    deadline = int(o["funding_deadline"].timestamp())
    if deadline <= int(datetime.now(timezone.utc).timestamp()) + 600:
        raise conflict("funding_deadline_passed", "Funding deadline is in the past; submit a new request with a longer window")
    steps = [
        {"step": "register", "contract": contract, "function": "registerInvoice", "signer": "ISSUER role holder",
         "args": {"p": {"invoiceHash": o["invoice_hash"], "documentHash": "0x" + docs[0]["sha256"], "debtorRef": o["debtor_ref"],
                        "business": o["payout_wallet"], "debtor": o["debtor_wallet"] or ZERO_ADDRESS,
                        "faceValue": str(int(o["face_value_base"])), "issueDate": _unix(inv["issue_date"]),
                        "dueDate": _unix(o["maturity_date"])}}},
        {"step": "verify", "contract": contract, "function": "verifyInvoice", "signer": "VERIFIER role holder",
         "args": {"invoiceId": "<from InvoiceRegistered event>", "debtorAckRef": o["debtor_ack_hash"]},
         "note": "Only after off-chain debtor acknowledgement has been reviewed (done: status APPROVED)."},
        {"step": "list", "contract": contract, "function": "createOffer", "signer": "OPERATOR role holder",
         "args": {"invoiceId": "<from InvoiceRegistered event>", "advance": str(int(o["advance_base"])), "fundingDeadline": deadline}},
    ]
    done = [bool(o.get("onchain_registered_at")), bool(o.get("onchain_verified_at")), False]
    nxt = next((st for st, d in zip(steps, done) if not d), None)
    if o.get("onchain_registered_at"):
        steps[1]["args"]["invoiceId"] = steps[2]["args"]["invoiceId"] = str(int(o["onchain_offer_id"]))
        nxt = next((st for st, d in zip(steps, done) if not d), None)
    return {"offer_id": o["id"], "status": o["status"], "chain_id": s.whitechain_chain_id, "next_step": nxt,
            "remaining_steps": [st["step"] for st, d in zip(steps, done) if not d],
            "message": "The backend does not send these transactions. A wallet holding the stated role must sign them; "
                       "status changes only when the resulting events are verified on-chain."}


# ───────────────────────── tx verification ─────────────────────────
def verify_tx(user: CurrentUser, tx_hash: str, s: Settings) -> dict:
    res = verify_transaction(get_blockchain(s), tx_hash, ("financing",))
    out = {k: getattr(res, k) for k in ("tx_hash", "stage", "detail", "confirmations", "required_confirmations", "block_number",
                                        "explorer_url", "events", "payment_ids", "offer_ids")}
    if res.stage in ("verified", "confirmed") and user.role != "admin":
        mine = _biz_of(user) if user.role == "merchant" else None
        ok = False
        with transaction() as c:
            for oid in res.offer_ids:
                o = repo.get_offer(c, oid)
                inv = repo.investment_for_offer(c, oid)
                if o and ((mine and o["business_id"] == mine) or (inv and inv["investor_id"] == user.id)
                          or (user.role == "investor" and o["status"] in INVESTOR_VISIBLE and user.wallet_address)):
                    ok = True
        if not ok:
            out.update(events=[], offer_ids=[], detail="Transaction verified but it is not related to your account")
    return out


# ───────────────────────── investments ─────────────────────────
def serialize_investment(v: dict, s: Settings) -> dict:
    d = v["token_decimals"]
    return {"id": v["id"], "offer_id": v["offer_id"], "invoice_id": v["invoice_id"], "invoice_number": v["invoice_number"],
            "investor_wallet": v["investor_wallet"], "amount": money(v["amount_base"], d), "amount_base": str(int(v["amount_base"])),
            "expected_repayment": money(v["face_value_base"], d), "status": v["status"], "offer_status": v["offer_status"],
            "maturity_date": v["maturity_date"], "funded_at": v["funded_at"],
            "repayment_amount": money(v["repayment_base"], d) if v["repayment_base"] is not None else None,
            "repayment_tx_hash": v["repayment_tx_hash"], "settled_at": v["settled_at"], "tx_hash": v["tx_hash"],
            "explorer_url": explorer_tx(s, v["tx_hash"])}


def list_investments(user: CurrentUser, pg: PageParams, s: Settings, settled_only: bool = False):
    kw: dict = {}
    if user.role == "investor":
        kw["investor_id"] = user.id
    elif user.role == "merchant":
        biz = _biz_of(user)
        if biz is None:
            return [], 0
        kw["business_id"] = biz
    elif user.role != "admin":
        raise forbidden()
    with transaction() as c:
        rows, total = repo.list_investments(c, settled_only=settled_only, pg=pg, **kw)
    return [serialize_investment(v, s) for v in rows], total


def get_investment(user: CurrentUser, inv_id, s: Settings) -> dict:
    with transaction() as c:
        v = repo.get_investment(c, inv_id)
    mine = _biz_of(user) if user.role == "merchant" else None
    if v is None or not (user.role == "admin" or (user.role == "investor" and v["investor_id"] == user.id)
                         or (user.role == "merchant" and mine and v["business_id"] == mine)):
        raise not_found("Investment", "investment_not_found")
    return serialize_investment(v, s)
