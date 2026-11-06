"""Four user journeys: merchant, investor (onboarding -> verification), admin (no public signup), customer (no account)."""
import pytest

from tests.helpers import token

API = "/api/v1"
ONB = {"full_name": "Ada Investor", "country": "UK", "investor_type": "individual", "accept_terms": True, "accept_risk": True}


def test_signup_cannot_request_admin(client):
    r = client.post(f"{API}/auth/signup", json={"email": "a@b.io", "password": "password123", "role": "admin"})
    assert r.status_code == 422
    r = client.post(f"{API}/auth/signup", json={"email": "a@b.io", "password": "password123", "role": "customer"})
    assert r.status_code == 422  # customers never sign up


def test_db_trigger_clamps_metadata_role_to_non_admin(w):
    u = w.user("customer")  # metadata role 'customer'
    assert w.c.execute("select role from profiles where id=%s", (u["id"],)).fetchone()["role"] == "customer"
    w.c.execute("insert into auth.users (id, email, raw_user_meta_data) values (gen_random_uuid(), 'x@x.io', '{\"role\":\"admin\"}')")
    assert w.c.execute("select role from profiles where email='x@x.io'").fetchone()["role"] == "customer"


def test_investor_onboarding_to_verified(w, client):
    inv, adm = w.user("investor", verified=False), w.user("admin")
    # unverified investors cannot see the marketplace
    r = client.get(f"{API}/financing/offers", headers=inv["h"])
    assert r.status_code == 403 and r.json()["error"]["code"] == "investor_not_verified"
    assert client.get(f"{API}/investors/me/onboarding", headers=inv["h"]).json() is None
    # admin cannot verify before submission
    r = client.patch(f"{API}/admin/users/{inv['id']}/investor-verification", json={"decision": "verify"}, headers=adm["h"])
    assert r.status_code == 409 and r.json()["error"]["code"] == "investor_not_submitted"

    r = client.post(f"{API}/investors/me/onboarding", json=ONB, headers=inv["h"])
    assert r.status_code == 201 and r.json()["verification"] == "pending"
    assert client.get(f"{API}/users/me", headers=inv["h"]).json()["investor_verification"] == "pending"
    # locked while pending
    assert client.post(f"{API}/investors/me/onboarding", json=ONB, headers=inv["h"]).status_code == 409
    assert client.get(f"{API}/financing/offers", headers=inv["h"]).status_code == 403

    # rejection allows resubmission
    client.patch(f"{API}/admin/users/{inv['id']}/investor-verification", json={"decision": "reject", "notes": "ID unclear"}, headers=adm["h"])
    got = client.get(f"{API}/investors/me/onboarding", headers=inv["h"]).json()
    assert got["verification"] == "rejected" and got["review_notes"] == "ID unclear"
    assert client.post(f"{API}/investors/me/onboarding", json=ONB, headers=inv["h"]).status_code == 201

    client.patch(f"{API}/admin/users/{inv['id']}/investor-verification", json={"decision": "verify"}, headers=adm["h"])
    assert client.get(f"{API}/financing/offers", headers=inv["h"]).status_code == 200
    assert client.post(f"{API}/investors/me/onboarding", json=ONB, headers=inv["h"]).status_code == 409


@pytest.mark.parametrize("patch", [{"accept_terms": False}, {"accept_risk": False}, {"investor_type": "institution"}, {"role": "admin"}])
def test_investor_onboarding_validation(w, client, patch):
    inv = w.user("investor", verified=False)
    r = client.post(f"{API}/investors/me/onboarding", json={**ONB, **patch}, headers=inv["h"])
    assert r.status_code in (400, 422)


def test_onboarding_roles_enforced(w, client):
    for role in ("merchant", "customer", "admin"):
        u = w.user(role)
        assert client.post(f"{API}/investors/me/onboarding", json=ONB, headers=u["h"]).status_code == 403
    assert client.post(f"{API}/investors/me/onboarding", json=ONB).status_code == 401


def test_admin_creation_only_by_admin(w, client):
    adm, mer, inv = w.user("admin"), w.user("merchant"), w.user("investor")
    body = {"email": "new.admin@test.io", "password": "a-long-password-1", "display_name": "New Admin"}
    for u in (mer, inv):
        assert client.post(f"{API}/admin/users", json=body, headers=u["h"]).status_code == 403
    assert client.post(f"{API}/admin/users", json=body).status_code == 401
    assert client.post(f"{API}/admin/users", json={**body, "password": "short"}, headers=adm["h"]).status_code == 422
    r = client.post(f"{API}/admin/users", json=body, headers=adm["h"])
    assert r.status_code == 201 and r.json()["role"] == "admin"
    # the new admin is recognised from the DATABASE, using a normal Supabase token
    h = {"Authorization": "Bearer " + token(r.json()["id"])}
    assert client.get(f"{API}/admin/users", headers=h).status_code == 200
    assert client.post(f"{API}/admin/users", json=body, headers=adm["h"]).status_code == 409
    assert w.c.execute("select count(*) n from audit_logs where action='admin_created'").fetchone()["n"] == 1


def test_customer_public_checkout_needs_no_account(client):
    # unknown link -> clean 404 from the PUBLIC endpoint (no auth header at all)
    r = client.get(f"{API}/public/invoices/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    assert r.status_code == 404
