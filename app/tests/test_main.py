import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import main  # noqa: E402


@pytest.fixture
def client(monkeypatch):
    for var in ("SQL_SERVER", "SQL_DATABASE", "SAMPLE_API_KEY", "STORAGE_BLOB_ENDPOINT"):
        monkeypatch.delenv(var, raising=False)
    main.app.config.update(TESTING=True)
    return main.app.test_client()


def test_health_is_always_ok(client):
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.get_json() == {"status": "ok"}


def test_index_reports_slot(client, monkeypatch):
    monkeypatch.setenv("WEBSITE_SLOT_NAME", "staging")
    body = client.get("/").get_json()
    assert body["slot"] == "staging"
    assert body["service"] == "alz-paas-sample"


def test_ready_skips_unconfigured_dependencies(client):
    resp = client.get("/ready")
    assert resp.status_code == 200
    checks = resp.get_json()["checks"]
    assert all(c["status"] == "skipped" for c in checks.values())


def test_unresolved_key_vault_reference_is_reported(client, monkeypatch):
    monkeypatch.setenv("SAMPLE_API_KEY", "@Microsoft.KeyVault(SecretUri=https://kv/secrets/x)")
    resp = client.get("/ready")
    assert resp.status_code == 503
    assert resp.get_json()["checks"]["key_vault_reference"]["status"] == "error"


def test_resolved_key_vault_reference_is_ok(client, monkeypatch):
    monkeypatch.setenv("SAMPLE_API_KEY", "x" * 40)
    resp = client.get("/ready")
    assert resp.status_code == 200
    assert resp.get_json()["checks"]["key_vault_reference"] == {"status": "ok", "length": 40}


def test_sql_failure_returns_503(client, monkeypatch):
    monkeypatch.setenv("SQL_SERVER", "example.database.windows.net")
    monkeypatch.setenv("SQL_DATABASE", "db")
    monkeypatch.setattr(main, "check_sql", lambda: {"status": "error", "error": "OperationalError"})
    resp = client.get("/ready")
    assert resp.status_code == 503
    assert resp.get_json()["status"] == "degraded"
