from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Depends, Query, Response
from typing import Annotated

from app.core.config import Settings, get_settings
from app.core.dependencies import MerchantBiz, Merchant, Pagination
from app.schemas.business import (BusinessCreate, BusinessOut, BusinessUpdate, CustomerCreate, CustomerOut, CustomerUpdate,
                                  MemberAdd, MemberOut)
from app.schemas.common import ERRORS, Page
from app.services import business_service as svc

router = APIRouter(tags=["Business & Customers"], responses=ERRORS)


@router.post("/businesses", response_model=BusinessOut, status_code=201, summary="Create my business (merchants without one)")
def create_business(body: BusinessCreate, user: Merchant):
    return svc.create(user, body)


@router.get("/businesses/me", response_model=BusinessOut, summary="My business")
def my_business(ctx: MerchantBiz):
    return svc.get(ctx)


@router.patch("/businesses/me", response_model=BusinessOut, summary="Update my business (owner only)")
def update_business(body: BusinessUpdate, ctx: MerchantBiz):
    return svc.update(ctx, body)


@router.get("/businesses/me/members", response_model=list[MemberOut], summary="List members")
def members(ctx: MerchantBiz):
    return svc.members(ctx)


@router.post("/businesses/me/members", response_model=MemberOut, status_code=201, summary="Add an existing merchant user (owner only)")
def add_member(body: MemberAdd, ctx: MerchantBiz):
    return svc.add_member(ctx, body.email)


@router.delete("/businesses/me/members/{user_id}", status_code=204, summary="Remove a member (owner only)")
def remove_member(user_id: UUID, ctx: MerchantBiz):
    svc.remove_member(ctx, user_id)
    return Response(status_code=204)


@router.post("/customers", response_model=CustomerOut, status_code=201, summary="Create customer")
def create_customer(body: CustomerCreate, ctx: MerchantBiz):
    return svc.create_customer(ctx, body)


@router.get("/customers", response_model=Page[CustomerOut], summary="List customers")
def list_customers(ctx: MerchantBiz, pg: Pagination, q: str | None = Query(None, max_length=100), include_archived: bool = False):
    rows, total = svc.list_customers(ctx, q, include_archived, pg)
    return Page(items=rows, page=pg.page, page_size=pg.page_size, total=total)


@router.get("/customers/{customer_id}", response_model=CustomerOut, summary="Get customer")
def get_customer(customer_id: UUID, ctx: MerchantBiz):
    return svc.get_customer(ctx, customer_id)


@router.patch("/customers/{customer_id}", response_model=CustomerOut, summary="Update customer")
def update_customer(customer_id: UUID, body: CustomerUpdate, ctx: MerchantBiz):
    return svc.update_customer(ctx, customer_id, body)


@router.delete("/customers/{customer_id}", status_code=204, summary="Archive customer (soft delete; invoices keep their history)")
def archive_customer(customer_id: UUID, ctx: MerchantBiz):
    svc.archive_customer(ctx, customer_id)
    return Response(status_code=204)
