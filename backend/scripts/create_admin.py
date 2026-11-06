"""Bootstrap the FIRST admin (later admins are created from the admin console: POST /api/v1/admin/users).

    cd backend && python -m scripts.create_admin admin@example.com "Admin Name"      # password prompted

Needs DATABASE_URL, SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY in the environment / .env.
"""
from __future__ import annotations

import getpass
import sys

from app.core.config import get_settings
from app.core.database import close_pool, init_pool, transaction
from app.repositories import profiles as prof
from app.repositories.system import audit
from app.services.supabase_client import GoTrue


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    email, name = sys.argv[1].strip().lower(), (sys.argv[2] if len(sys.argv) > 2 else None)
    password = getpass.getpass("Password (min 12 chars): ")
    if len(password) < 12 or password != getpass.getpass("Repeat password: "):
        print("Passwords differ or are shorter than 12 characters.")
        return 1
    s = get_settings()
    init_pool(s.database_url, 1, 2)
    try:
        with transaction() as c:
            if prof.get_by_email(c, email):
                print("An account with this email already exists; promote it from the admin console instead.")
                return 1
        user = GoTrue(s).admin_create_user(email, password, name)
        with transaction() as c:
            prof.set_role(c, user["id"], "admin")
            audit(c, user["id"], "admin_bootstrapped", "profile", user["id"], {"email": email})
        print(f"Admin created: {email} ({user['id']})")
        return 0
    finally:
        close_pool()


if __name__ == "__main__":
    raise SystemExit(main())
