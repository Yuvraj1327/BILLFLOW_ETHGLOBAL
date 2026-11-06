from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends

from app.core.config import Settings, get_settings
from app.core.database import transaction
from app.core.dependencies import Investor
from app.core.exceptions import bad_request, conflict
from app.repositories.system import audit
from app.schemas.common import ERRORS
from app.schemas.user import InvestorOnboardingIn, InvestorOnboardingOut, ProfileOut
from app.services import financing_service as fin

router = APIRouter(prefix="/investors", tags=["Investors"], responses=ERRORS)


def _onboarding(c, user_id) -> dict | None:
    return c.execute("""select ip.full_name, ip.country, ip.investor_type, ip.organization, ip.tax_id, ip.submitted_at, ip.review_notes,
                        p.investor_verification as verification from investor_profiles ip join profiles p on p.id = ip.user_id
                        where ip.user_id = %s""", (user_id,)).fetchone()


@router.get("/me/onboarding", response_model=InvestorOnboardingOut | None, summary="My onboarding submission and verification status")
def get_onboarding(user: Investor):
    with transaction() as c:
        return _onboarding(c, user.id)


@router.post("/me/onboarding", response_model=InvestorOnboardingOut, status_code=201,
             summary="Submit investor onboarding; moves verification to 'pending' for admin review")
def submit_onboarding(body: InvestorOnboardingIn, user: Investor):
    """Allowed while unverified or after a rejection (resubmission). A verified or pending investor cannot overwrite the record."""
    if not (body.accept_terms and body.accept_risk):
        raise bad_request("consent_required", "You must accept the terms and the risk disclosure")
    if body.investor_type == "institution" and not body.organization:
        raise bad_request("organization_required", "Organization name is required for institutions")
    with transaction() as c:
        status = c.execute("select investor_verification v from profiles where id=%s for update", (user.id,)).fetchone()["v"]
        if status in ("pending", "verified"):
            raise conflict("onboarding_locked", f"Onboarding is already {status}")
        c.execute("""insert into investor_profiles (user_id, full_name, country, investor_type, organization, tax_id, accepted_terms_at,
                       accepted_risk_at, submitted_at, review_notes, reviewed_by, reviewed_at)
                     values (%s,%s,%s,%s,%s,%s, now(), now(), now(), null, null, null)
                     on conflict (user_id) do update set full_name=excluded.full_name, country=excluded.country,
                       investor_type=excluded.investor_type, organization=excluded.organization, tax_id=excluded.tax_id,
                       accepted_terms_at=now(), accepted_risk_at=now(), submitted_at=now(), review_notes=null,
                       reviewed_by=null, reviewed_at=null""",
                  (user.id, body.full_name, body.country, body.investor_type, body.organization, body.tax_id))
        c.execute("update profiles set investor_verification='pending', display_name=coalesce(display_name, %s) where id=%s",
                  (body.full_name, user.id))
        audit(c, user.id, "investor_onboarding_submitted", "profile", user.id, {"type": body.investor_type, "country": body.country})
        return _onboarding(c, user.id)


@router.get("/me/portfolio", summary="Portfolio summary (computed from verified on-chain data only)")
def portfolio(user: Investor, s: Annotated[Settings, Depends(get_settings)]):
    with transaction() as c:
        r = c.execute("""select count(*) filter (where v.status in ('CONFIRMED','SETTLED')) as positions,
                         coalesce(sum(v.amount_base) filter (where v.status='CONFIRMED'),0) as active_base,
                         coalesce(sum(f.face_value_base) filter (where v.status='CONFIRMED'),0) as expected_base,
                         coalesce(sum(v.repayment_base) filter (where v.status='SETTLED'),0) as returned_base,
                         coalesce(sum(v.amount_base) filter (where v.status='SETTLED'),0) as settled_principal_base
                         from investments v join financing_offers f on f.id=v.offer_id where v.investor_id=%s""", (user.id,)).fetchone()
        dec = c.execute("select coalesce(max(token_decimals), %s) d from invoices", (s.usdt_decimals or 6,)).fetchone()["d"]
    from app.utils.validators import from_base
    return {"wallet_address": user.wallet_address, "verification": _verif(user.id), "positions": r["positions"],
            "active_invested": from_base(r["active_base"], dec), "expected_repayment": from_base(r["expected_base"], dec),
            "settled_principal": from_base(r["settled_principal_base"], dec), "returned": from_base(r["returned_base"], dec),
            "note": "Funding is done by the investor's own wallet; the backend only records verified on-chain events."}


def _verif(user_id) -> str:
    with transaction() as c:
        return c.execute("select investor_verification v from profiles where id=%s", (user_id,)).fetchone()["v"]
