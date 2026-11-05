"""One error envelope for every failure: {"error": {"code", "message", "details"}}."""
from __future__ import annotations

import logging
from typing import Any

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

log = logging.getLogger("billflow.errors")


class AppError(Exception):
    def __init__(self, status: int, code: str, message: str, details: dict[str, Any] | None = None):
        super().__init__(message)
        self.status, self.code, self.message, self.details = status, code, message, details or {}


def bad_request(code: str, msg: str, **d: Any) -> AppError:
    return AppError(400, code, msg, d)


def unauthorized(msg: str = "Authentication required", code: str = "unauthorized") -> AppError:
    return AppError(401, code, msg)


def forbidden(msg: str = "You do not have permission to do this", code: str = "forbidden") -> AppError:
    return AppError(403, code, msg)


def not_found(what: str = "Resource", code: str = "not_found") -> AppError:
    return AppError(404, code, f"{what} not found")


def conflict(code: str, msg: str, **d: Any) -> AppError:
    return AppError(409, code, msg, d)


def upstream(code: str, msg: str, **d: Any) -> AppError:
    return AppError(502, code, msg, d)


def unavailable(code: str, msg: str) -> AppError:
    return AppError(503, code, msg)


def _body(code: str, message: str, details: dict | None = None) -> dict:
    return {"error": {"code": code, "message": message, "details": details or {}}}


def install_handlers(app: FastAPI) -> None:
    @app.exception_handler(AppError)
    async def _app_error(_: Request, exc: AppError):
        return JSONResponse(status_code=exc.status, content=_body(exc.code, exc.message, exc.details))

    @app.exception_handler(RequestValidationError)
    async def _validation(_: Request, exc: RequestValidationError):
        fields = [{"loc": ".".join(str(p) for p in e["loc"]), "msg": e["msg"], "type": e["type"]} for e in exc.errors()]
        return JSONResponse(status_code=422, content=_body("validation_error", "Request validation failed", {"fields": fields}))

    @app.exception_handler(StarletteHTTPException)
    async def _http(_: Request, exc: StarletteHTTPException):
        return JSONResponse(status_code=exc.status_code, content=_body(f"http_{exc.status_code}", str(exc.detail)))

    @app.exception_handler(Exception)
    async def _unhandled(_: Request, exc: Exception):
        log.exception("unhandled error")  # details stay in server logs only
        return JSONResponse(status_code=500, content=_body("internal_error", "Internal server error"))
