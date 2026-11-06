"""Open CORS for the token-scoped PUBLIC checkout endpoints only, so the embeddable widget works on any merchant site.

Safe because: these endpoints are authorised by an unguessable link token (never cookies/ambient credentials; we never send
`Allow-Credentials`), are rate limited, and expose only checkout data. Every other path keeps the configured allow-list."""
from __future__ import annotations

from starlette.types import ASGIApp, Message, Receive, Scope, Send

_ALLOW = [(b"access-control-allow-origin", b"*"), (b"access-control-allow-methods", b"GET, POST, OPTIONS"),
          (b"access-control-allow-headers", b"content-type"), (b"access-control-max-age", b"600")]


class PublicCorsMiddleware:
    def __init__(self, app: ASGIApp, prefix: str):
        self.app, self.prefix = app, prefix

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http" or not scope["path"].startswith(self.prefix):
            return await self.app(scope, receive, send)
        if scope["method"] == "OPTIONS":
            await send({"type": "http.response.start", "status": 204, "headers": _ALLOW})
            await send({"type": "http.response.body", "body": b""})
            return

        async def wrapped(msg: Message) -> None:
            if msg["type"] == "http.response.start":
                # Replace, never append: the app-wide CORSMiddleware (dev localhost regex) may already have set this header, and
                # browsers reject a response carrying two Access-Control-Allow-Origin values.
                msg["headers"] = [*(h for h in msg.get("headers", []) if h[0].lower() != b"access-control-allow-origin"), *_ALLOW[:1]]
            await send(msg)

        await self.app(scope, receive, wrapped)
