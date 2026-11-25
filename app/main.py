"""Sample workload for the landing zone.

Endpoints:
  /           basic info (no secrets)
  /health     liveness probe used by App Service health check and Application Gateway
  /ready      readiness check: Azure SQL (managed identity), Key Vault reference, Blob storage
"""

import logging
import os
import time

from flask import Flask, jsonify

app = Flask(__name__)
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("alz-app")

START_TIME = time.time()


def check_sql() -> dict:
    """Connect to Azure SQL with the web app's managed identity (no password)."""
    server = os.getenv("SQL_SERVER")
    database = os.getenv("SQL_DATABASE")
    if not server or not database:
        return {"status": "skipped", "reason": "SQL_SERVER or SQL_DATABASE not set"}

    import pyodbc  # imported lazily so /health works even if the ODBC driver is missing

    conn_str = (
        "Driver={ODBC Driver 18 for SQL Server};"
        f"Server=tcp:{server},1433;Database={database};"
        "Encrypt=yes;TrustServerCertificate=no;Connection Timeout=15;"
        "Authentication=ActiveDirectoryMsi;"
    )
    started = time.perf_counter()
    try:
        with pyodbc.connect(conn_str) as conn:
            row = conn.cursor().execute("SELECT @@SERVERNAME, DB_NAME()").fetchone()
        return {
            "status": "ok",
            "server": row[0],
            "database": row[1],
            "latency_ms": round((time.perf_counter() - started) * 1000, 1),
        }
    except Exception as exc:  # noqa: BLE001 - report any connection failure
        log.exception("SQL readiness check failed")
        return {"status": "error", "error": type(exc).__name__, "detail": str(exc)[:300]}


def check_key_vault_reference() -> dict:
    """App Service resolves @Microsoft.KeyVault(...) settings before the app starts.
    If resolution fails, the raw reference string is left in the variable."""
    value = os.getenv("SAMPLE_API_KEY")
    if value is None:
        return {"status": "skipped", "reason": "SAMPLE_API_KEY not set"}
    if value.startswith("@Microsoft.KeyVault"):
        return {"status": "error", "error": "Key Vault reference not resolved (check identity RBAC and networking)"}
    return {"status": "ok", "length": len(value)}


def check_storage() -> dict:
    endpoint = os.getenv("STORAGE_BLOB_ENDPOINT")
    if not endpoint:
        return {"status": "skipped", "reason": "STORAGE_BLOB_ENDPOINT not set"}
    try:
        from azure.identity import ManagedIdentityCredential
        from azure.storage.blob import BlobServiceClient

        client = BlobServiceClient(account_url=endpoint, credential=ManagedIdentityCredential())
        container = client.get_container_client("uploads")
        exists = container.exists()
        return {"status": "ok" if exists else "error", "container_exists": exists}
    except Exception as exc:  # noqa: BLE001
        log.exception("Storage readiness check failed")
        return {"status": "error", "error": type(exc).__name__, "detail": str(exc)[:300]}


@app.get("/")
def index():
    return jsonify(
        service="alz-paas-sample",
        instance=os.getenv("WEBSITE_INSTANCE_ID", "local")[:12],
        slot=os.getenv("WEBSITE_SLOT_NAME", "production"),
        uptime_seconds=round(time.time() - START_TIME),
    )


@app.get("/health")
def health():
    # Liveness only: must stay fast and must not depend on downstream services,
    # otherwise a database blip would make App Service recycle healthy instances.
    return jsonify(status="ok"), 200


@app.get("/ready")
def ready():
    checks = {
        "sql": check_sql(),
        "key_vault_reference": check_key_vault_reference(),
        "storage": check_storage(),
    }
    healthy = all(c["status"] in ("ok", "skipped") for c in checks.values())
    return jsonify(status="ok" if healthy else "degraded", checks=checks), (200 if healthy else 503)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", "8000")))
