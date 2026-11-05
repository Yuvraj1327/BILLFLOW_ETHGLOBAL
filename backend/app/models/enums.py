"""Status vocabularies (mirror the Postgres enums) and allowed transitions."""
from __future__ import annotations

INVOICE_STATUSES = ("DRAFT", "PENDING", "PARTIALLY_PAID", "PAID", "OVERDUE", "CANCELLED")
FINANCING_STATUSES = ("REQUESTED", "UNDER_REVIEW", "APPROVED", "LISTED", "FUNDED", "SETTLED", "REJECTED",
                      "EXPIRED", "CANCELLED", "DEFAULTED")

# Invoice transitions. PARTIALLY_PAID/PAID are applied ONLY by verified blockchain events.
INVOICE_TRANSITIONS: dict[str, set[str]] = {
    "DRAFT": {"PENDING", "CANCELLED"},
    "PENDING": {"PARTIALLY_PAID", "PAID", "OVERDUE", "CANCELLED"},
    "PARTIALLY_PAID": {"PAID", "OVERDUE"},
    "OVERDUE": {"PARTIALLY_PAID", "PAID", "CANCELLED"},
    "PAID": set(),
    "CANCELLED": set(),
}
CHAIN_ONLY_INVOICE_STATUSES = {"PARTIALLY_PAID", "PAID"}

# Financing transitions. LISTED/FUNDED/SETTLED/EXPIRED/DEFAULTED are applied ONLY by verified events.
FINANCING_TRANSITIONS: dict[str, set[str]] = {
    "REQUESTED": {"UNDER_REVIEW", "APPROVED", "REJECTED", "CANCELLED"},
    "UNDER_REVIEW": {"APPROVED", "REJECTED", "CANCELLED"},
    "APPROVED": {"LISTED", "REJECTED", "CANCELLED"},
    "LISTED": {"FUNDED", "CANCELLED", "EXPIRED"},
    "FUNDED": {"SETTLED", "DEFAULTED"},
    "DEFAULTED": {"SETTLED"},
    "SETTLED": set(), "REJECTED": set(), "CANCELLED": set(), "EXPIRED": set(),
}
# Mapping to the labels used in the product brief (for UI / docs).
FINANCING_DISPLAY = {"REQUESTED": "SUBMITTED", "UNDER_REVIEW": "UNDER_REVIEW", "APPROVED": "VERIFIED",
                     "LISTED": "AVAILABLE", "FUNDED": "ACTIVE", "SETTLED": "SETTLED", "DEFAULTED": "OVERDUE",
                     "CANCELLED": "CANCELLED", "REJECTED": "REJECTED", "EXPIRED": "EXPIRED"}


def can_invoice_transition(cur: str, new: str) -> bool:
    return new in INVOICE_TRANSITIONS.get(cur, set())


def can_financing_transition(cur: str, new: str) -> bool:
    return new in FINANCING_TRANSITIONS.get(cur, set())
