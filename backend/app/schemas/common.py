from __future__ import annotations

from typing import Any, Generic, TypeVar

from pydantic import BaseModel, ConfigDict

T = TypeVar("T")


class Page(BaseModel, Generic[T]):
    items: list[T]
    page: int
    page_size: int
    total: int


class Message(BaseModel):
    message: str


class ErrorDetail(BaseModel):
    code: str
    message: str
    details: dict[str, Any] = {}


class ErrorResponse(BaseModel):
    error: ErrorDetail


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


ERRORS = {400: {"model": ErrorResponse, "description": "Bad request"},
          401: {"model": ErrorResponse, "description": "Missing/invalid/expired token"},
          403: {"model": ErrorResponse, "description": "Role or ownership forbids this"},
          404: {"model": ErrorResponse, "description": "Not found"},
          409: {"model": ErrorResponse, "description": "State conflict / duplicate"},
          422: {"model": ErrorResponse, "description": "Validation failed"}}
