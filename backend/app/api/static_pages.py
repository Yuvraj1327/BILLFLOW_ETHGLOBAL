"""Hosted checkout page + the embeddable widget script (served by the API so one deployment hosts everything)."""
from __future__ import annotations

from pathlib import Path
from typing import Annotated

from fastapi import APIRouter, Path as PathParam
from fastapi.responses import FileResponse, HTMLResponse

STATIC = Path(__file__).resolve().parent.parent / "static"
router = APIRouter(include_in_schema=False)
_HEADERS = {"X-Content-Type-Options": "nosniff", "Referrer-Policy": "no-referrer"}


@router.get("/billflow.js")
def widget_js():
    # Public, cacheable for a short time; merchants embed it cross-origin with a plain <script> tag.
    return FileResponse(STATIC / "billflow.js", media_type="application/javascript",
                        headers={**_HEADERS, "Cache-Control": "public, max-age=300", "Access-Control-Allow-Origin": "*"})


@router.get("/pay/{token}", response_class=HTMLResponse)
def hosted_checkout(token: Annotated[str, PathParam(min_length=32, max_length=128, pattern=r"^[A-Za-z0-9_\-]+$")]):
    """The token is read client-side from the URL; nothing is interpolated into the HTML (no injection surface)."""
    html = (STATIC / "pay.html").read_text(encoding="utf-8")
    return HTMLResponse(html, headers={
        **_HEADERS, "Cache-Control": "no-store", "X-Frame-Options": "DENY",
        "Content-Security-Policy": "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; connect-src 'self'; "
                                   "img-src 'self' data:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"})
