from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, Path

from app.core.config import Settings, get_settings
from app.core.database import transaction
from app.core.dependencies import Admin, AnyUser
from app.core.exceptions import not_found
from app.repositories import chain as chain_repo
from app.schemas.common import ERRORS
from app.schemas.payment import TX_HASH
from app.services.blockchain_service import get_blockchain
from app.services.payment_service import signer_address

router = APIRouter(prefix="/blockchain", tags=["Blockchain"], responses=ERRORS)
Cfg = Annotated[Settings, Depends(get_settings)]


@router.get("/config", summary="Public chain configuration for wallets/clients (no secrets)")
def config(user: AnyUser, s: Cfg):
    return {"chain_id": s.whitechain_chain_id, "explorer_url": s.whitechain_explorer_url, "usdt_address": s.whitechain_usdt_address or None,
            "usdt_decimals": s.usdt_decimals, "payments_contract": s.whitechain_payment_contract or None,
            "financing_contract": s.whitechain_financing_contract or None, "min_confirmations": s.min_confirmations,
            "quote_signer": signer_address(s), "configured": bool(s.whitechain_usdt_address and s.whitechain_payment_contract
                                                              and s.whitechain_financing_contract and s.usdt_decimals is not None)}


@router.get("/health", summary="Admin: preflight against the live chain (addresses really are the expected contracts)")
def health(admin: Admin, s: Cfg):
    checks = get_blockchain(s).preflight(signer_address(s))
    with transaction() as c:
        cursor = chain_repo.get_last_block(c, s.whitechain_chain_id, "billflow:combined")
    return {"ok": all(v["ok"] for v in checks.values()), "checks": checks, "indexer_cursor": cursor,
            "note": "Live checks only pass with a reachable RPC and deployed contracts."}


@router.get("/transactions/{tx_hash}", summary="Tracked status of a transaction hash")
def tx(admin: Admin, s: Cfg, tx_hash: Annotated[str, Path(pattern=TX_HASH)]):
    with transaction() as c:
        r = chain_repo.get_tx(c, tx_hash.lower())
    if r is None:
        raise not_found("Transaction", "transaction_not_found")
    return {**r, "explorer_url": get_blockchain(s).explorer_tx_url(r["tx_hash"])}
