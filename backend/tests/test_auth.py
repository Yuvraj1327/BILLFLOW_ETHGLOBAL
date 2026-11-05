import time
import uuid

import jwt
from eth_account import Account
from eth_account.messages import encode_defunct

from tests.helpers import SECRET, token

API = "/api/v1"


def test_health_and_docs(client):
    assert client.get("/health").json()["database"] is True
    assert client.get("/openapi.json").status_code == 200
    assert client.get("/docs").status_code == 200


def test_no_token_401(client):
    r = client.get(f"{API}/users/me")
    assert r.status_code == 401 and r.json()["error"]["code"] == "unauthorized"


def test_valid_token_returns_db_role(w, client):
    u = w.user("merchant")
    r = client.get(f"{API}/users/me", headers=u["h"])
    assert r.status_code == 200 and r.json()["role"] == "merchant"


def test_invalid_signature_rejected(w, client):
    u = w.user("merchant")
    bad = token(u["id"], secret="x" * 40)
    r = client.get(f"{API}/users/me", headers={"Authorization": f"Bearer {bad}"})
    assert r.status_code == 401 and r.json()["error"]["code"] == "invalid_token"


def test_expired_token(w, client):
    u = w.user("merchant")
    r = client.get(f"{API}/users/me", headers={"Authorization": f"Bearer {token(u['id'], exp_in=-10)}"})
    assert r.status_code == 401 and r.json()["error"]["code"] == "token_expired"


def test_wrong_audience_and_alg_none(w, client):
    u = w.user("merchant")
    r = client.get(f"{API}/users/me", headers={"Authorization": f"Bearer {token(u['id'], aud='other')}"})
    assert r.status_code == 401
    forged = jwt.encode({"sub": str(u["id"]), "aud": "authenticated", "exp": int(time.time()) + 99}, "", algorithm="none")
    assert client.get(f"{API}/users/me", headers={"Authorization": f"Bearer {forged}"}).status_code == 401


def test_token_without_profile_forbidden(client):
    r = client.get(f"{API}/users/me", headers={"Authorization": f"Bearer {token(uuid.uuid4())}"})
    assert r.status_code == 403 and r.json()["error"]["code"] == "no_profile"


def test_frontend_cannot_choose_role(w, client):
    """A role claim inside the JWT or request body must be ignored: the DB profile decides."""
    u = w.user("customer")
    h = {"Authorization": "Bearer " + token(u["id"], app_metadata={"role": "admin"}, user_metadata={"role": "admin"})}
    assert client.get(f"{API}/admin/users", headers=h).status_code == 403
    r = client.patch(f"{API}/users/me", json={"display_name": "x", "role": "admin"}, headers=u["h"])
    assert r.status_code == 422  # extra field rejected
    assert client.get(f"{API}/users/me", headers=u["h"]).json()["role"] == "customer"


def test_rbac_matrix(w, client):
    cust, inv, adm, mer = w.user("customer"), w.user("investor"), w.user("admin"), w.user("merchant")
    assert client.get(f"{API}/invoices", headers=cust["h"]).status_code == 403
    assert client.get(f"{API}/invoices", headers=inv["h"]).status_code == 403
    assert client.get(f"{API}/admin/users", headers=mer["h"]).status_code == 403
    assert client.get(f"{API}/admin/users", headers=adm["h"]).status_code == 200
    assert client.get(f"{API}/investors/me/portfolio", headers=mer["h"]).status_code == 403
    assert client.get(f"{API}/investors/me/portfolio", headers=inv["h"]).status_code == 200


def test_admin_cannot_self_assign_via_signup_and_cannot_change_own_role(w, client, authc):
    r = client.post(f"{API}/auth/signup", json={"email": "a@b.io", "password": "password1", "role": "admin"})
    assert r.status_code == 422
    adm = w.user("admin")
    r = client.patch(f"{API}/admin/users/{adm['id']}/role", json={"role": "customer"}, headers=adm["h"])
    assert r.status_code == 409


def test_signup_login_refresh_logout(client, authc):
    r = client.post(f"{API}/auth/signup", json={"email": "m@x.io", "password": "password1", "role": "merchant"})
    assert r.status_code == 201 and r.json()["confirmation_required"] is True
    assert client.post(f"{API}/auth/login", json={"email": "m@x.io", "password": "nope"}).status_code == 401
    ok = client.post(f"{API}/auth/login", json={"email": "m@x.io", "password": "password1"})
    assert ok.status_code == 200 and ok.json()["access_token"] == "at"
    assert client.post(f"{API}/auth/refresh", json={"refresh_token": "r" * 12}).json()["access_token"] == "at2"


def test_wallet_link_flow(w, client):
    u = w.user("investor")
    acct = Account.create()
    ch = client.post(f"{API}/auth/wallet/challenge", json={"wallet_address": acct.address}, headers=u["h"]).json()
    sig = acct.sign_message(encode_defunct(text=ch["message"])).signature.hex()
    ok = client.post(f"{API}/auth/wallet/verify", json={"wallet_address": acct.address, "nonce": ch["nonce"], "signature": sig}, headers=u["h"])
    assert ok.status_code == 200 and ok.json()["wallet_address"] == acct.address.lower()
    # single use
    again = client.post(f"{API}/auth/wallet/verify", json={"wallet_address": acct.address, "nonce": ch["nonce"], "signature": sig}, headers=u["h"])
    assert again.status_code == 400
    # a different account cannot claim the same wallet
    other = w.user("investor")
    assert client.post(f"{API}/auth/wallet/challenge", json={"wallet_address": acct.address}, headers=other["h"]).status_code == 409


def test_wallet_signature_by_wrong_key_rejected(w, client):
    u = w.user("investor")
    acct, thief = Account.create(), Account.create()
    ch = client.post(f"{API}/auth/wallet/challenge", json={"wallet_address": acct.address}, headers=u["h"]).json()
    sig = thief.sign_message(encode_defunct(text=ch["message"])).signature.hex()
    r = client.post(f"{API}/auth/wallet/verify", json={"wallet_address": acct.address, "nonce": ch["nonce"], "signature": sig}, headers=u["h"])
    assert r.status_code == 400 and r.json()["error"]["code"] == "invalid_signature"
