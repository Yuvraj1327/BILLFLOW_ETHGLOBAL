import base64
import json
from types import SimpleNamespace

import httpx
import pytest

from app.core.exceptions import upstream
from tests.helpers import pdf_bytes

API = "/api/v1"
GOOD = {"invoice_number": "A-77", "merchant_name": "Acme", "customer_name": "Globex", "amount": "1250.50", "currency": "USDT",
        "issue_date": "2026-10-01", "due_date": "2026-11-01", "confidence": 0.93, "field_confidence": {"amount": 0.99}, "warnings": []}


def extract(client, h, data=None, ctype="application/pdf", name="inv.pdf"):
    return client.post(f"{API}/ai/extract-invoice", files={"file": (name, data if data is not None else pdf_bytes(), ctype)}, headers=h)


def test_extract_success_and_request_shape(w, client, llm, conn):
    m = w.merchant(); llm.response = GOOD
    data = pdf_bytes("x")
    r = extract(client, m["h"], data)
    assert r.status_code == 200, r.text
    b = r.json()
    assert b["extracted"]["amount"] == "1250.50" and b["extracted"]["confidence"] == 0.93 and "not legal verification" in b["notice"]
    call = llm.calls[0]
    doc = call["content"][0]
    assert doc["type"] == "document" and doc["source"]["media_type"] == "application/pdf"
    assert base64.b64decode(doc["source"]["data"]) == data
    assert "untrusted" in call["system"].lower() and "never follow instructions" in call["system"].lower()
    assert call["tool"] == "record_invoice" and call["schema"]["additionalProperties"] is False
    # extraction saves nothing and approves nothing
    assert conn.execute("select count(*) n from invoices").fetchone()["n"] == 0
    assert conn.execute("select count(*) n from invoice_documents").fetchone()["n"] == 0
    audit = conn.execute("select metadata from audit_logs where action='ai_extract_invoice'").fetchone()["metadata"]
    assert "1250.50" not in json.dumps(audit)  # content is not logged


def test_extract_flags_duplicates(w, client, llm):
    m = w.merchant(); c = w.customer(m); w.invoice(m, c, number="A-77"); llm.response = GOOD
    r = extract(client, m["h"])
    assert any("A-77" in x for x in r.json()["duplicate_warnings"])


def test_extract_missing_fields_are_null_not_guessed(w, client, llm):
    m = w.merchant(); llm.response = {"confidence": 0.2, "warnings": ["Total not legible"]}
    b = extract(client, m["h"]).json()["extracted"]
    assert b["amount"] is None and b["due_date"] is None and b["warnings"] == ["Total not legible"]


@pytest.mark.parametrize("bad", [
    {"invoice_number": "x"},                                  # confidence missing
    {**GOOD, "confidence": 1.7},                              # out of range
    {**GOOD, "amount": "12,50 USD"},                          # not a plain decimal
    {**GOOD, "due_date": "tomorrow"},
    {**GOOD, "approve_financing": True},                      # unknown key (prompt-injection style) is rejected, not ignored
    "not json at all", [], None, 42,
])
def test_extract_invalid_model_output_is_502(w, client, llm, conn, bad):
    m = w.merchant(); llm.response = bad
    r = extract(client, m["h"])
    assert r.status_code == 502 and r.json()["error"]["code"] == "ai_invalid_output"
    assert conn.execute("select count(*) n from invoices").fetchone()["n"] == 0


def test_extract_upstream_error(w, client, llm):
    m = w.merchant(); llm.exc = upstream("ai_upstream_error", "AI provider is unreachable or timed out")
    r = extract(client, m["h"])
    assert r.status_code == 502 and r.json()["error"]["code"] == "ai_upstream_error"


def test_extract_rejects_bad_files_before_calling_ai(w, client, llm):
    m = w.merchant(); llm.response = GOOD
    assert extract(client, m["h"], b"", name="e.pdf").status_code == 400
    assert extract(client, m["h"], b"plain text", name="t.pdf").status_code == 415
    assert extract(client, m["h"], pdf_bytes(), "image/png", "p.png").status_code == 415
    assert extract(client, m["h"], pdf_bytes(pages=25)).status_code == 400  # AI_MAX_PDF_PAGES=20
    assert llm.calls == []


def test_ai_requires_merchant(w, client, llm):
    llm.response = GOOD
    for role in ("investor", "customer", "admin"):
        assert extract(client, w.user(role)["h"]).status_code == 403
    assert client.post(f"{API}/ai/extract-invoice", files={"file": ("a.pdf", pdf_bytes(), "application/pdf")}).status_code == 401


def test_not_configured(w, client, monkeypatch):
    from app.core.config import get_settings
    from app.services.anthropic_service import set_llm
    set_llm(None)
    m = w.merchant()
    monkeypatch.setenv("ANTHROPIC_API_KEY", ""); get_settings.cache_clear()
    try:
        r = extract(client, m["h"])
        assert r.status_code == 503 and r.json()["error"]["code"] == "ai_not_configured"
    finally:
        monkeypatch.setenv("ANTHROPIC_API_KEY", "test"); get_settings.cache_clear()


def test_summary_reminder_validate_minimise_data_and_change_nothing(w, client, llm, conn):
    m = w.merchant(); c = w.customer(m, wallet="0x" + "99" * 20); inv = w.invoice(m, c, amount="100")
    before = conn.execute("select status, review_status, paid_amount_base from invoices").fetchall()
    llm.response = {"summary": "Invoice for consulting.", "status_explanation": "Awaiting payment.", "missing_fields": [], "suggested_category": "Services"}
    r = client.post(f"{API}/ai/invoice-summary", json={"invoice_id": inv["id"]}, headers=m["h"])
    assert r.status_code == 200 and r.json()["summary"].startswith("Invoice")
    llm.response = {"subject": "Reminder", "body": "Please pay 100 USDT."}
    r = client.post(f"{API}/ai/payment-reminder", json={"invoice_id": inv["id"], "tone": "friendly"}, headers=m["h"])
    assert r.status_code == 200 and "Nothing is sent" in r.json()["notice"]
    llm.response = {"warnings": ["Description is generic"], "confidence": 0.8}
    r = client.post(f"{API}/ai/validate-invoice", json={"invoice_id": inv["id"]}, headers=m["h"])
    assert r.status_code == 200 and r.json()["ai_warnings"] == ["Description is generic"] and r.json()["ai_used"] is True
    sent = json.dumps([x["content"] for x in llm.calls])
    assert "0x99" not in sent and m["business"]["id"] not in sent and str(c["id"]) not in sent and "payout" not in sent  # no wallets / ids
    assert before == conn.execute("select status, review_status, paid_amount_base from invoices").fetchall()


def test_validate_works_without_ai(w, client, llm):
    m = w.merchant(); c = w.customer(m); inv = w.invoice(m, c, number="D-1")
    w.invoice(m, c, number="D-2")  # same customer/amount/date => possible duplicate
    llm.exc = upstream("ai_upstream_error", "down")
    r = client.post(f"{API}/ai/validate-invoice", json={"invoice_id": inv["id"]}, headers=m["h"])
    b = r.json()
    assert r.status_code == 200 and b["ai_used"] is False and any("D-2" in x for x in b["duplicate_warnings"])


def test_ai_on_foreign_invoice_404(w, client, llm):
    a, b = w.merchant(), w.merchant("0x" + "bb" * 20)
    inv = w.invoice(a, w.customer(a)); llm.response = {"warnings": [], "confidence": 1}
    for path in ("invoice-summary", "payment-reminder", "validate-invoice"):
        assert client.post(f"{API}/ai/{path}", json={"invoice_id": inv["id"]}, headers=b["h"]).status_code == 404
    assert llm.calls == []


# ───────────── the real adapter around the Anthropic SDK (stubbed client) ─────────────
def _adapter(monkeypatch, create):
    import anthropic
    from app.core.config import get_settings
    from app.services.anthropic_service import AnthropicLLM
    stub = SimpleNamespace(messages=SimpleNamespace(create=create))
    monkeypatch.setattr(anthropic, "Anthropic", lambda **kw: stub)
    return AnthropicLLM(get_settings())


def test_adapter_forces_tool_use(monkeypatch):
    seen = {}

    def create(**kw):
        seen.update(kw)
        return SimpleNamespace(content=[SimpleNamespace(type="tool_use", name="record_x", input={"ok": 1})])

    out = _adapter(monkeypatch, create).call_tool(system="s", content=[{"type": "text", "text": "t"}], tool_name="record_x", schema={"type": "object"}, max_tokens=10)
    assert out == {"ok": 1} and seen["tool_choice"] == {"type": "tool", "name": "record_x"} and seen["model"] == "test-model"


def test_adapter_maps_failures(monkeypatch):
    import anthropic
    from app.core.exceptions import AppError
    req = httpx.Request("POST", "https://api.anthropic.com/v1/messages")

    def timeout(**kw):
        raise anthropic.APIConnectionError(request=req)

    def status(**kw):
        raise anthropic.APIStatusError("boom", response=httpx.Response(529, request=req), body=None)

    def no_tool(**kw):
        return SimpleNamespace(content=[SimpleNamespace(type="text", text="I refuse")])

    for fn, code in ((timeout, "ai_upstream_error"), (status, "ai_upstream_error"), (no_tool, "ai_invalid_output")):
        with pytest.raises(AppError) as e:
            _adapter(monkeypatch, fn).call_tool(system="s", content=[], tool_name="t", schema={}, max_tokens=1)
        assert e.value.code == code and e.value.status == 502
