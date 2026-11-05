"""Step 5 hardening tests: docs toggle and bounded rate-limit memory."""
from app.core import dependencies as deps


def test_rate_limit_table_is_bounded(monkeypatch):
    deps.reset_rate_limits()
    import time
    old = time.monotonic() - 120
    for i in range(10_050):
        deps._hits[f"1.1.{i // 250}.{i % 250}"].append(old)

    class R:
        client = type("C", (), {"host": "9.9.9.9"})()

    class S:
        public_rate_limit_per_minute = 5

    deps.public_rate_limit(R(), S())
    assert len(deps._hits) < 100  # stale entries purged
    deps.reset_rate_limits()


def test_docs_can_be_disabled(monkeypatch):
    monkeypatch.setenv("ENABLE_DOCS", "false")
    from app.core.config import get_settings
    get_settings.cache_clear()
    from fastapi.testclient import TestClient
    from app.main import create_app
    c = TestClient(create_app())
    assert c.get("/docs").status_code == 404
    assert c.get("/openapi.json").status_code == 404
    get_settings.cache_clear()
