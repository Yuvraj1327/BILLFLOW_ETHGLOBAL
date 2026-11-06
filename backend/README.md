# NEXA BILLFLOW backend
See `../docs/BACKEND_API.md` for the full guide. Run: `cp .env.example .env` (fill it in) · `pip install -r requirements.txt` · `uvicorn app.main:app --reload` · Swagger at `/docs`.
Indexer: `python -m app.workers.blockchain_indexer`. Tests: `pip install -r requirements-dev.txt && pytest`.

## Roles & onboarding
- Public signup is merchant/investor only (`role` is a request; the DB trigger and `profiles.role` decide). Customers never sign up.
- Investors: `POST /investors/me/onboarding` → `pending` → admin `PATCH /admin/users/{id}/investor-verification`. Unverified investors get 403 `investor_not_verified` on marketplace endpoints.
- Admins: first one via `python -m scripts.create_admin <email> [name]`; later ones via `POST /admin/users` (admin only). Apply `supabase/migrations/0005_investor_onboarding.sql`.
