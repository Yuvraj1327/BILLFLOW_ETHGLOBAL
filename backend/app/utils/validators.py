from __future__ import annotations

import json
import re
from datetime import date
from decimal import Decimal, InvalidOperation
from typing import Any
from uuid import UUID

from eth_utils import is_address, keccak, to_checksum_address

from app.core.exceptions import bad_request

ZERO_ADDRESS = "0x" + "00" * 20
_HEX32 = re.compile(r"^0x[0-9a-fA-F]{64}$")


def norm_address(value: str, field: str = "address") -> str:
    """Lower-case, validated 0x address (DB stores lower-case)."""
    if not isinstance(value, str) or not is_address(value):
        raise bad_request("invalid_address", f"{field} is not a valid EVM address", field=field)
    return value.lower()


def norm_hash32(value: str, field: str = "hash") -> str:
    if not isinstance(value, str) or not _HEX32.match(value):
        raise bad_request("invalid_hash", f"{field} must be a 32-byte 0x hex string", field=field)
    return value.lower()


def checksum(addr: str) -> str:
    return to_checksum_address(addr)


def to_base(amount: str, decimals: int, field: str = "amount") -> int:
    """Decimal string -> integer base units. Rejects >decimals places, <=0, NaN/inf, exponents."""
    s = str(amount).strip()
    if not re.fullmatch(r"\d+(\.\d+)?", s):
        raise bad_request("invalid_amount", f"{field} must be a plain decimal number", field=field)
    try:
        d = Decimal(s)
    except InvalidOperation:  # pragma: no cover
        raise bad_request("invalid_amount", f"{field} is not a number", field=field)
    scaled = d * (Decimal(10) ** decimals)
    if scaled != scaled.to_integral_value():
        raise bad_request("invalid_amount", f"{field} has more than {decimals} decimal places", field=field)
    n = int(scaled)
    if n <= 0:
        raise bad_request("invalid_amount", f"{field} must be greater than zero", field=field)
    if n >= 10**30:
        raise bad_request("invalid_amount", f"{field} is too large", field=field)
    return n


def from_base(n: int | Decimal | None, decimals: int) -> str | None:
    if n is None:
        return None
    d = Decimal(int(n)) / (Decimal(10) ** decimals)
    s = format(d, "f")
    return s.rstrip("0").rstrip(".") if "." in s else s


def keccak_hex(data: bytes) -> str:
    return "0x" + keccak(data).hex()


def onchain_invoice_id(invoice_uuid: UUID | str) -> str:
    """bytes32 invoice id used by BillFlowPayments: keccak256(utf8(uuid))."""
    return keccak_hex(str(invoice_uuid).encode())


def canonical_invoice_hash(*, invoice_id: UUID | str, business_id: UUID | str, customer_id: UUID | str,
                           invoice_number: str, amount_base: int, token_decimals: int, currency: str,
                           issue_date: date, due_date: date) -> str:
    """FROZEN recipe: keccak256 of compact, key-sorted JSON. Changing it breaks every existing invoice hash."""
    payload = {
        "amount_base": str(int(amount_base)), "business_id": str(business_id), "currency": currency,
        "customer_id": str(customer_id), "due_date": due_date.isoformat(), "invoice_id": str(invoice_id),
        "invoice_number": invoice_number, "issue_date": issue_date.isoformat(), "token_decimals": int(token_decimals),
    }
    return keccak_hex(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode())


def hash_json(obj: Any) -> str:
    return keccak_hex(json.dumps(obj, sort_keys=True, separators=(",", ":"), default=str).encode())
