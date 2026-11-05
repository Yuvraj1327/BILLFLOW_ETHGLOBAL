"""Notifications, audit logs, platform settings."""
from __future__ import annotations

import json
from typing import Any
from uuid import UUID

from psycopg import Connection
from psycopg.types.json import Jsonb


def notify(c: Connection, user_id: UUID | str | None, type_: str, title: str, body: str | None = None) -> None:
    if user_id is None:
        return
    c.execute("insert into notifications (user_id, type, title, body) values (%s,%s,%s,%s)", (user_id, type_, title, body))


def notify_admins(c: Connection, type_: str, title: str, body: str | None = None) -> None:
    c.execute("insert into notifications (user_id, type, title, body) select id, %s, %s, %s from profiles where role='admin'",
              (type_, title, body))


def notify_business(c: Connection, business_id: UUID | str, type_: str, title: str, body: str | None = None) -> None:
    c.execute("""insert into notifications (user_id, type, title, body)
                 select u, %s, %s, %s from (
                   select owner_id as u from businesses where id=%s
                   union select user_id from business_members where business_id=%s) t""",
              (type_, title, body, business_id, business_id))


def audit(c: Connection, actor_id: UUID | str | None, action: str, entity_type: str, entity_id: Any = None,
          metadata: dict | None = None) -> None:
    c.execute("insert into audit_logs (actor_id, action, entity_type, entity_id, metadata) values (%s,%s,%s,%s,%s)",
              (actor_id, action, entity_type, str(entity_id) if entity_id is not None else None, Jsonb(metadata or {})))


def get_setting(c: Connection, key: str, default: Any = None) -> Any:
    r = c.execute("select value from platform_settings where key=%s", (key,)).fetchone()
    return r["value"] if r else default


def list_settings(c: Connection) -> list[dict]:
    return c.execute("select key, value, updated_by, updated_at from platform_settings order by key").fetchall()


def set_setting(c: Connection, key: str, value: Any, user_id: UUID | str) -> None:
    c.execute("""insert into platform_settings (key, value, updated_by) values (%s,%s,%s)
                 on conflict (key) do update set value=excluded.value, updated_by=excluded.updated_by, updated_at=now()""",
              (key, Jsonb(value), user_id))
