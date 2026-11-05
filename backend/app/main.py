"""BillFlow API entrypoint. Run: uvicorn app.main:app --reload"""
from __future__ import annotations

import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.api import admin, ai, auth, blockchain, businesses, financing, investors, invoices, payments, public, users
from app.core.config import get_settings
from app.core.database import close_pool, init_pool, ping, pool_ready
from app.core.exceptions import install_handlers
from app.core.logging import setup_logging

TAGS = [{"name": "Auth", "description": "Supabase-backed sign-up/login and wallet linking. Roles come from the database."},
        {"name": "Users"}, {"name": "Business & Customers"}, {"name": "Invoices"}, {"name": "Payments"},
        {"name": "Financing", "description": "Off-chain review; on-chain state only changes through verified contract events."},
        {"name": "Investors"}, {"name": "AI (advisory only)", "description": "Claude suggestions; never approvals."},
        {"name": "Blockchain"}, {"name": "Public checkout", "description": "Unauthenticated, token-scoped, rate limited."},
        {"name": "Admin"}, {"name": "System"}]


@asynccontextmanager
async def lifespan(app: FastAPI):
    s = get_settings()
    setup_logging(s.log_level)
    if s.database_url:
        init_pool(s.database_url)
    stop = None
    if s.indexer_enabled:
        from app.workers.blockchain_indexer import start_background
        stop = start_background(s)
    yield
    if stop is not None:
        stop.set()
    close_pool()


def create_app() -> FastAPI:
    s = get_settings()
    app = FastAPI(title="BillFlow API", version="0.3.0", lifespan=lifespan, openapi_tags=TAGS,
                  description="Web3 invoicing, USDT payments and invoice financing on Whitechain Sepolia (chain 1874). "
                              "Send `Authorization: Bearer <Supabase access token>`.")
    if s.cors_list:
        app.add_middleware(CORSMiddleware, allow_origins=s.cors_list, allow_methods=["*"], allow_headers=["*"], allow_credentials=False)
    install_handlers(app)
    for r in (auth.router, users.router, businesses.router, invoices.router, payments.router, financing.router,
              investors.router, ai.router, blockchain.router, admin.router, public.router):
        app.include_router(r, prefix=s.api_prefix)

    @app.get("/health", tags=["System"], summary="Liveness + database reachability")
    def health():
        return {"status": "ok" if pool_ready() and ping() else "degraded", "database": pool_ready() and ping(), "chain_id": s.whitechain_chain_id}

    return app


app = create_app()
