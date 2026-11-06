from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Query

from app.core.database import transaction
from app.core.dependencies import AnyUser, Pagination
from app.core.exceptions import not_found
from app.repositories import businesses as biz_repo
from app.repositories import profiles as prof
from app.schemas.common import ERRORS, Message, Page
from app.schemas.user import ProfileOut, ProfileUpdate

router = APIRouter(tags=["Users"], responses=ERRORS)


def load_profile(user_id) -> dict:
    with transaction() as c:
        p = prof.get(c, user_id)
        b = None
        if p and p["role"] == "merchant":
            b = biz_repo.business_of_user(c, user_id) or biz_repo.ensure_business(c, user_id, p["display_name"], p["email"])
    return {**p, "business_id": b["id"] if b else None}


@router.get("/users/me", response_model=ProfileOut, summary="My profile")
def get_me(user: AnyUser):
    return load_profile(user.id)


@router.patch("/users/me", response_model=ProfileOut, summary="Update my display name (role/wallet cannot be set here)")
def patch_me(body: ProfileUpdate, user: AnyUser):
    with transaction() as c:
        prof.update_basic(c, user.id, body.display_name)
    return load_profile(user.id)


@router.get("/notifications", summary="My notifications")
def notifications(user: AnyUser, pg: Pagination, unread_only: bool = Query(False)):
    with transaction() as c:
        w = "user_id=%s" + (" and read_at is null" if unread_only else "")
        total = c.execute(f"select count(*) n from notifications where {w}", (user.id,)).fetchone()["n"]
        rows = c.execute(f"select id, type, title, body, read_at, created_at from notifications where {w} "
                         "order by created_at desc limit %s offset %s", (user.id, pg.page_size, pg.offset)).fetchall()
    return {"items": rows, "page": pg.page, "page_size": pg.page_size, "total": total}


@router.post("/notifications/{notification_id}/read", response_model=Message, summary="Mark one notification read")
def mark_read(notification_id: UUID, user: AnyUser):
    with transaction() as c:
        r = c.execute("update notifications set read_at=coalesce(read_at, now()) where id=%s and user_id=%s returning 1",
                      (notification_id, user.id)).fetchone()
    if not r:
        raise not_found("Notification", "notification_not_found")
    return Message(message="ok")


@router.post("/notifications/read-all", response_model=Message, summary="Mark all my notifications read")
def mark_all(user: AnyUser):
    with transaction() as c:
        c.execute("update notifications set read_at=now() where user_id=%s and read_at is null", (user.id,))
    return Message(message="ok")
