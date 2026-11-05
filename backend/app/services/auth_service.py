"""Wallet ownership proof (EIP-191). Roles are never taken from the client."""
from __future__ import annotations

from datetime import datetime, timezone

from eth_account import Account
from eth_account.messages import encode_defunct

from app.core.config import Settings
from app.core.database import transaction
from app.core.exceptions import bad_request, conflict
from app.core.security import new_opaque_token
from app.repositories import profiles as prof
from app.repositories.system import audit
from app.utils.validators import checksum, norm_address


def _message(wallet: str, nonce: str, chain_id: int) -> str:
    return (f"BillFlow wallet verification\nWallet: {checksum(wallet)}\nNonce: {nonce}\nChain ID: {chain_id}\n"
            "Signing this message does not move funds or grant any permission.")


def create_challenge(user_id, wallet_address: str, settings: Settings) -> dict:
    wallet = norm_address(wallet_address, "wallet_address")
    nonce = new_opaque_token(16)
    with transaction() as c:
        owner = prof.get_by_wallet(c, wallet)
        if owner and owner["id"] != user_id:
            raise conflict("wallet_in_use", "This wallet is already linked to another account")
        row = prof.create_challenge(c, user_id, wallet, nonce)
    return {"nonce": nonce, "message": _message(wallet, nonce, settings.whitechain_chain_id), "expires_at": row["expires_at"]}


def verify_challenge(user_id, wallet_address: str, nonce: str, signature: str, settings: Settings) -> dict:
    wallet = norm_address(wallet_address, "wallet_address")
    try:
        recovered = Account.recover_message(encode_defunct(text=_message(wallet, nonce, settings.whitechain_chain_id)),
                                            signature=signature).lower()
    except Exception as e:  # noqa: BLE001
        raise bad_request("invalid_signature", "Signature is malformed") from e
    if recovered != wallet:
        raise bad_request("invalid_signature", "Signature does not match the wallet")
    with transaction() as c:
        if not prof.consume_challenge(c, user_id, wallet, nonce):  # single-use + expiry enforced in SQL
            raise bad_request("challenge_invalid", "Challenge is unknown, expired or already used")
        owner = prof.get_by_wallet(c, wallet)
        if owner and owner["id"] != user_id:
            raise conflict("wallet_in_use", "This wallet is already linked to another account")
        row = prof.set_wallet(c, user_id, wallet)
        audit(c, user_id, "wallet_linked", "profile", user_id, {"wallet": wallet})
    return row
