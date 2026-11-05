"""Idempotent application of VERIFIED blockchain events to Supabase/Postgres.

This is the ONLY code path that may set invoice status PAID/PARTIALLY_PAID or financing status
LISTED/FUNDED/SETTLED/EXPIRED/DEFAULTED. It is shared by the indexer and by the tx-hash verification
endpoints, so a client-supplied hash can never take a shortcut around the same validation.
"""
from __future__ import annotations

import logging
from dataclasses import dataclass, field
from typing import Callable

from psycopg import Connection

from app.core.config import Settings
from app.core.database import transaction
from app.models.enums import can_financing_transition
from app.repositories import chain as chain_repo
from app.repositories import financing as fin_repo
from app.repositories import invoices as inv_repo
from app.repositories import payments as pay_repo
from app.repositories import profiles as prof_repo
from app.repositories.system import audit, notify, notify_admins, notify_business
from app.services.blockchain_service import BlockchainService, DecodedEvent

log = logging.getLogger("billflow.events")


@dataclass
class Outcome:
    status: str  # applied | duplicate | ignored | rejected | retry
    detail: str = ""
    payment_id: str | None = None
    offer_id: str | None = None


def _rej(why: str) -> Outcome:
    return Outcome("rejected", why)


def _retry(why: str) -> Outcome:
    return Outcome("retry", why)


# ───────────────────────── payments ─────────────────────────
def _invoice_paid(c: Connection, ev: DecodedEvent, s: Settings) -> Outcome:
    a = ev.args
    if ev.contract != s.whitechain_payment_contract:
        return _rej("wrong_contract")
    inv = inv_repo.get_by_onchain_id(c, a["invoiceId"], lock=True)
    if inv is None:
        return _rej("unknown_invoice")
    if inv["invoice_hash"] != a["invoiceHash"]:
        return _rej("invoice_hash_mismatch")
    if not inv["payout_wallet"] or inv["payout_wallet"] != a["merchant"]:
        return _rej("merchant_mismatch")
    total, amount, paid = int(inv["amount_base"]), int(a["amount"]), int(a["totalPaid"])
    if int(a["invoiceTotal"]) != total:
        return _rej("invoice_total_mismatch")
    if amount <= 0 or paid > total or paid < amount:
        return _rej("amount_inconsistent")
    p = pay_repo.insert_if_new(c, inv["id"], a["payer"], amount, ev.tx_hash, ev.log_index, ev.block_number)
    if p is None:
        return Outcome("duplicate", "payment already recorded")
    new_paid = max(int(inv["paid_amount_base"]), paid)
    new_status = "PAID" if new_paid == total else "PARTIALLY_PAID"
    upd: dict = {"paid_amount_base": new_paid}
    if inv["status"] == "CANCELLED":
        audit(c, None, "payment_on_cancelled_invoice", "invoice", inv["id"], {"tx_hash": ev.tx_hash})
    elif inv["status"] != "PAID":
        upd["status"] = new_status
        if new_status == "PAID":
            upd["paid_tx_hash"] = ev.tx_hash
    inv_repo.update(c, inv["id"], upd)
    notify_business(c, inv["business_id"], "invoice_payment_received", f"Payment received for invoice {inv['invoice_number']}",
                    f"{amount} base units paid; invoice is now {upd.get('status', inv['status'])}.")
    return Outcome("applied", new_status, payment_id=str(p["id"]))


# ───────────────────────── financing ─────────────────────────
def _transition(c: Connection, offer: dict, new: str, extra: dict | None = None) -> Outcome:
    if offer["status"] == new:
        return Outcome("duplicate", f"already {new}", offer_id=str(offer["id"]))
    if not can_financing_transition(offer["status"], new):
        return _rej(f"invalid_transition_{offer['status']}_to_{new}")
    fin_repo.update_offer(c, offer["id"], {"status": new, **(extra or {})})
    return Outcome("applied", new, offer_id=str(offer["id"]))


def _offer_by_chain_id(c: Connection, ev: DecodedEvent) -> dict | None:
    return fin_repo.get_offer_by_onchain_id(c, ev.args["invoiceId"], lock=True)


def _registered(c: Connection, ev: DecodedEvent, s: Settings) -> Outcome:
    a = ev.args
    offer = fin_repo.get_offer_by_hash(c, a["invoiceHash"], lock=True)
    if offer is None:
        return Outcome("ignored", "not an invoice known to BillFlow")
    if offer["status"] not in ("REQUESTED", "UNDER_REVIEW", "APPROVED"):
        return _rej(f"registered_while_{offer['status']}")
    if not offer["payout_wallet"] or offer["payout_wallet"] != a["business"]:
        return _rej("business_wallet_mismatch")
    if int(a["faceValue"]) != int(offer["face_value_base"]):
        return _rej("face_value_mismatch")
    if offer["onchain_offer_id"] is not None:
        if str(int(offer["onchain_offer_id"])) == a["invoiceId"]:
            return Outcome("duplicate", "already linked", offer_id=str(offer["id"]))
        return _rej("conflicting_onchain_id")
    fin_repo.update_offer(c, offer["id"], {"onchain_offer_id": int(a["invoiceId"]), "onchain_registered_at": _now(c),
                                           "document_hash": a["documentHash"], "debtor_ref": a["debtorRef"],
                                           "create_tx_hash": None})
    return Outcome("applied", "registered on-chain", offer_id=str(offer["id"]))


def _verified(c: Connection, ev: DecodedEvent, s: Settings) -> Outcome:
    offer = _offer_by_chain_id(c, ev)
    if offer is None:
        return _retry("registration event not processed yet")
    ack = ev.args["debtorAckRef"]
    if offer["debtor_ack_hash"] and offer["debtor_ack_hash"] != ack:
        return _rej("debtor_ack_hash_mismatch")
    upd = {"onchain_verified_at": _now(c)}
    if not offer["debtor_ack_hash"]:
        upd["debtor_ack_hash"] = ack
    fin_repo.update_offer(c, offer["id"], upd)
    return Outcome("applied", "verified on-chain", offer_id=str(offer["id"]))


def _created(c: Connection, ev: DecodedEvent, s: Settings) -> Outcome:
    a = ev.args
    offer = _offer_by_chain_id(c, ev)
    if offer is None:
        return _retry("registration event not processed yet")
    if int(a["advance"]) != int(offer["advance_base"]) or int(a["faceValue"]) != int(offer["face_value_base"]):
        return _rej("offer_terms_mismatch")
    if offer["status"] == "LISTED":
        return Outcome("duplicate", "already listed", offer_id=str(offer["id"]))
    if offer["status"] in ("REQUESTED", "UNDER_REVIEW"):
        audit(c, None, "offer_listed_without_offchain_approval", "financing_offer", offer["id"], {"tx_hash": ev.tx_hash})
    if offer["status"] in ("REQUESTED", "UNDER_REVIEW", "APPROVED"):
        fin_repo.update_offer(c, offer["id"], {"status": "LISTED", "create_tx_hash": ev.tx_hash,
                                               "funding_deadline": _ts(c, int(a["fundingDeadline"])), "onchain_listed_at": _now(c)})
        notify_business(c, offer["business_id"], "financing_offer_approved", "Financing offer is live",
                        f"Invoice {offer['invoice_number']} is now available to investors.")
        return Outcome("applied", "LISTED", offer_id=str(offer["id"]))
    return _rej(f"offer_created_while_{offer['status']}")


def _funded(c: Connection, ev: DecodedEvent, s: Settings) -> Outcome:
    a = ev.args
    offer = _offer_by_chain_id(c, ev)
    if offer is None:
        return _retry("registration event not processed yet")
    if offer["status"] in ("REQUESTED", "UNDER_REVIEW", "APPROVED"):
        return _retry("listing event not processed yet")
    if offer["status"] == "FUNDED" or fin_repo.investment_for_offer(c, offer["id"]):
        return Outcome("duplicate", "already funded", offer_id=str(offer["id"]))
    if offer["status"] != "LISTED":
        return _rej(f"funded_while_{offer['status']}")
    if int(a["advance"]) != int(offer["advance_base"]):
        return _rej("advance_mismatch")
    investor = prof_repo.get_by_wallet(c, a["investor"])
    if investor is None:
        return _retry("investor_wallet_not_linked")  # retried by the indexer once the investor links the wallet
    inv = fin_repo.insert_investment(c, offer["id"], investor["id"], a["investor"], int(a["advance"]), ev.tx_hash)
    if inv is None:
        return Outcome("duplicate", "investment already recorded", offer_id=str(offer["id"]))
    fin_repo.update_offer(c, offer["id"], {"status": "FUNDED"})
    notify_business(c, offer["business_id"], "investor_funded_invoice", "Your invoice was funded",
                    f"Invoice {offer['invoice_number']} received {a['advance']} base units.")
    notify(c, investor["id"], "investment_confirmed", "Investment confirmed", f"You funded invoice {offer['invoice_number']}.")
    return Outcome("applied", "FUNDED", offer_id=str(offer["id"]))


def _repaid(c: Connection, ev: DecodedEvent, s: Settings) -> Outcome:
    offer = _offer_by_chain_id(c, ev)
    inv = fin_repo.investment_for_offer(c, offer["id"]) if offer else None
    if offer is None or inv is None:
        return _retry("funding event not processed yet")
    if inv["repayment_tx_hash"] == ev.tx_hash:
        return Outcome("duplicate", "repayment already recorded", offer_id=str(offer["id"]))
    if int(ev.args["amount"]) != int(offer["face_value_base"]):
        return _rej("repayment_amount_mismatch")
    fin_repo.update_investment(c, inv["id"], {"repayment_base": int(ev.args["amount"]), "repayment_tx_hash": ev.tx_hash})
    notify(c, inv["investor_id"], "repayment_completed", "Repayment received", f"Invoice {offer['invoice_number']} was repaid.")
    notify_business(c, offer["business_id"], "repayment_completed", "Debtor repaid financed invoice", offer["invoice_number"])
    return Outcome("applied", "repayment recorded", offer_id=str(offer["id"]))


def _settled(c: Connection, ev: DecodedEvent, s: Settings) -> Outcome:
    offer = _offer_by_chain_id(c, ev)
    if offer is None:
        return _retry("registration event not processed yet")
    inv = fin_repo.investment_for_offer(c, offer["id"])
    if inv is None:
        return _retry("funding event not processed yet")
    out = _transition(c, offer, "SETTLED")
    if out.status != "applied":
        return out
    fin_repo.update_investment(c, inv["id"], {"status": "SETTLED", "settled_at": _now(c)})
    invoice = inv_repo.get(c, offer["invoice_id"], lock=True)
    if invoice and invoice["status"] not in ("PAID", "CANCELLED"):
        inv_repo.update(c, invoice["id"], {"status": "PAID", "paid_amount_base": invoice["amount_base"], "paid_tx_hash": ev.tx_hash})
    notify(c, inv["investor_id"], "settlement_completed", "Financing settled", offer["invoice_number"])
    notify_business(c, offer["business_id"], "settlement_completed", "Financing settled", offer["invoice_number"])
    return out


def _simple(new_status: str) -> Callable[[Connection, DecodedEvent, Settings], Outcome]:
    def h(c: Connection, ev: DecodedEvent, s: Settings) -> Outcome:
        offer = _offer_by_chain_id(c, ev)
        if offer is None:
            return Outcome("ignored", "unknown on-chain invoice")
        out = _transition(c, offer, new_status)
        if out.status == "applied":
            notify_business(c, offer["business_id"], f"financing_{new_status.lower()}", f"Financing {new_status.lower()}",
                            offer["invoice_number"])
        return out
    return h


def _business_approval(c: Connection, ev: DecodedEvent, s: Settings) -> Outcome:
    approved = bool(ev.args["approved"])
    row = c.execute("""update businesses set verification_status=%s::verification_status,
                       verified_at=case when %s then now() else null end
                       where payout_wallet=%s returning id""",
                    ("verified" if approved else "unverified", approved, ev.args["business"])).fetchone()
    return Outcome("applied", "business approval mirrored") if row else Outcome("ignored", "no business with that wallet")


def _investor_approval(c: Connection, ev: DecodedEvent, s: Settings) -> Outcome:
    approved = bool(ev.args["approved"])
    row = c.execute("update profiles set investor_verification=%s::verification_status where wallet_address=%s returning id",
                    ("verified" if approved else "unverified", ev.args["investor"])).fetchone()
    return Outcome("applied", "investor approval mirrored") if row else Outcome("ignored", "no investor with that wallet")


def _now(c: Connection):
    return c.execute("select now() as n").fetchone()["n"]


def _ts(c: Connection, unix: int):
    return c.execute("select to_timestamp(%s) as t", (unix,)).fetchone()["t"]


HANDLERS: dict[tuple[str, str], Callable[[Connection, DecodedEvent, Settings], Outcome]] = {
    ("payments", "InvoicePaid"): _invoice_paid,
    ("financing", "InvoiceRegistered"): _registered,
    ("financing", "InvoiceVerified"): _verified,
    ("financing", "OfferCreated"): _created,
    ("financing", "OfferFunded"): _funded,
    ("financing", "OfferRepaid"): _repaid,
    ("financing", "OfferSettled"): _settled,
    ("financing", "OfferCancelled"): _simple("CANCELLED"),
    ("financing", "InvoiceCancelled"): _simple("CANCELLED"),
    ("financing", "InvoiceRejected"): _simple("REJECTED"),
    ("financing", "OfferExpired"): _simple("EXPIRED"),
    ("financing", "OfferDefaulted"): _simple("DEFAULTED"),
    ("financing", "BusinessApprovalUpdated"): _business_approval,
    ("financing", "InvestorApprovalUpdated"): _investor_approval,
}


def process_event(ev: DecodedEvent, settings: Settings) -> Outcome:
    """Persist + apply one event atomically. Safe to call any number of times for the same log."""
    handler = HANDLERS.get((ev.kind, ev.name))
    with transaction() as c:
        row = chain_repo.insert_event(c, ev)
        if row["processed_at"] is not None:
            return Outcome("duplicate", "event already processed")
        if handler is None:
            chain_repo.mark_event(c, row["id"], True, None)
            return Outcome("ignored", "event type not tracked")
        out = handler(c, ev, settings)
        if out.status == "retry":
            chain_repo.mark_event(c, row["id"], False, out.detail)
        else:
            chain_repo.mark_event(c, row["id"], True, out.detail if out.status == "rejected" else None)
        if out.status == "rejected":
            log.warning("event rejected %s %s: %s", ev.name, ev.tx_hash, out.detail)
            notify_admins(c, "chain_event_rejected", f"{ev.name} rejected", f"{ev.tx_hash}: {out.detail}")
        return out


def retry_unprocessed(settings: Settings, limit: int = 100) -> int:
    """Re-apply events that were parked as 'retry' (e.g. investor wallet linked later). Returns applied count."""
    with transaction() as c:
        rows = chain_repo.unprocessed_events(c, limit)
    applied = 0
    for r in rows:
        ev = DecodedEvent(chain_id=r["chain_id"], contract=r["contract_address"],
                          kind="payments" if r["contract_address"] == settings.whitechain_payment_contract else "financing",
                          name=r["event_name"], tx_hash=r["tx_hash"], log_index=r["log_index"], block_number=r["block_number"],
                          block_hash=r["block_hash"], args=r["payload"])
        if process_event(ev, settings).status == "applied":
            applied += 1
    return applied


# ───────────────────────── transaction verification (hash submitted by a client) ─────────────────────────
@dataclass
class TxVerification:
    tx_hash: str
    stage: str  # not_found | submitted | failed | confirmed | rejected | verified
    detail: str = ""
    confirmations: int = 0
    required_confirmations: int = 0
    block_number: int | None = None
    explorer_url: str = ""
    events: list[dict] = field(default_factory=list)
    payment_ids: list[str] = field(default_factory=list)
    offer_ids: list[str] = field(default_factory=list)


def verify_transaction(chain: BlockchainService, tx_hash: str, kinds: tuple[str, ...]) -> TxVerification:
    """Independently verify a client-supplied hash against the chain. Never trusts the client's claim of success."""
    s = chain.s
    tx_hash = tx_hash.lower()
    res = TxVerification(tx_hash=tx_hash, stage="submitted", required_confirmations=s.min_confirmations,
                         explorer_url=chain.explorer_tx_url(tx_hash))
    kind = "invoice_payment" if kinds == ("payments",) else "financing"
    chain.assert_network()
    receipt = chain.client.get_receipt(tx_hash)
    if receipt is None:
        with transaction() as c:
            chain_repo.upsert_tx(c, tx_hash, s.whitechain_chain_id, kind, "SUBMITTED")
        res.stage, res.detail = "not_found", "Transaction not found on Whitechain yet (not mined or wrong network)"
        return res
    res.block_number = receipt.block_number
    if receipt.status != 1:
        with transaction() as c:
            chain_repo.upsert_tx(c, tx_hash, s.whitechain_chain_id, kind, "FAILED", from_address=receipt.from_address,
                                 to_address=receipt.to_address, block_number=receipt.block_number, block_hash=receipt.block_hash,
                                 error="transaction reverted")
        res.stage, res.detail = "failed", "Transaction reverted on-chain"
        return res
    res.confirmations = chain.confirmations(receipt)
    still_canonical = chain.client.get_block_hash(receipt.block_number) in (None, receipt.block_hash)
    confirmed = res.confirmations >= s.min_confirmations and still_canonical
    with transaction() as c:
        chain_repo.upsert_tx(c, tx_hash, s.whitechain_chain_id, kind, "CONFIRMED" if confirmed else "SUBMITTED",
                             from_address=receipt.from_address, to_address=receipt.to_address,
                             block_number=receipt.block_number, block_hash=receipt.block_hash, confirmations=res.confirmations)
    if not still_canonical:
        res.stage, res.detail = "submitted", "Block hash changed (reorg); waiting for the chain to settle"
        return res
    if not confirmed:
        res.stage, res.detail = "submitted", f"Waiting for confirmations ({res.confirmations}/{s.min_confirmations})"
        return res
    events = chain.decode_receipt(receipt, kinds)
    if not events:
        res.stage, res.detail = "rejected", "Transaction contains no BillFlow contract events from the configured contracts"
        return res
    if "payments" in kinds:  # cross-check the real USDT movement in the same receipt
        transfers = chain.usdt_transfers(receipt)
        for e in events:
            if e.name == "InvoicePaid" and not any(
                    t.args["from"] == e.args["payer"] and t.args["to"] == e.args["merchant"] and t.args["value"] == e.args["amount"]
                    for t in transfers):
                res.stage, res.detail = "rejected", "No matching transfer from the configured USDT contract in this transaction"
                return res
    res.stage = "confirmed"
    ok = True
    for e in events:
        out = process_event(e, s)
        res.events.append({"name": e.name, "log_index": e.log_index, "outcome": out.status, "detail": out.detail})
        if out.payment_id:
            res.payment_ids.append(out.payment_id)
        if out.offer_id:
            res.offer_ids.append(out.offer_id)
        ok = ok and out.status in ("applied", "duplicate", "ignored")
    if ok:
        res.stage = "verified"
        with transaction() as c:
            chain_repo.mark_tx_verified(c, tx_hash)
    else:
        res.stage = "rejected" if any(e["outcome"] == "rejected" for e in res.events) else "confirmed"
        res.detail = "; ".join(f"{e['name']}: {e['outcome']} {e['detail']}" for e in res.events if e["outcome"] in ("rejected", "retry"))
    return res
