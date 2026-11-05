from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends

from app.core.config import Settings, get_settings
from app.core.database import transaction
from app.core.dependencies import Investor, Pagination
from app.schemas.common import ERRORS
from app.services import financing_service as fin

router = APIRouter(prefix="/investors", tags=["Investors"], responses=ERRORS)


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
