"""Servicio web de la Evaluacion Final DGITI.

Expone endpoints de validacion (/health, /status, /api/info) y una API sencilla
que escribe en la base de datos primaria (RDS MySQL) y lee desde la replica.
"""
import hashlib
import os
import socket
import time
from datetime import datetime, timezone

import pymysql
from flask import Flask, jsonify, request

MAX_STRESS_MS = 2000

app = Flask(__name__)


def instance_metadata():
    """Datos de la instancia que atiende la peticion (sirve para ver el balanceo)."""
    return {
        "instance_id": os.environ.get("INSTANCE_ID", socket.gethostname()),
        "availability_zone": os.environ.get("AVAILABILITY_ZONE", "local"),
        "hostname": socket.gethostname(),
        "version": os.environ.get("APP_VERSION", "1.0.0"),
    }


def db_config(replica=False):
    host = os.environ.get("DB_HOST", "")
    if replica:
        host = os.environ.get("DB_REPLICA_HOST") or host
    return {
        "host": host,
        "port": int(os.environ.get("DB_PORT", "3306")),
        "user": os.environ.get("DB_USER", ""),
        "password": os.environ.get("DB_PASSWORD", ""),
        "database": os.environ.get("DB_NAME", "appdb"),
        "connect_timeout": 3,
        "read_timeout": 5,
        "write_timeout": 5,
        "autocommit": True,
        "cursorclass": pymysql.cursors.DictCursor,
    }


def get_connection(replica=False):
    config = db_config(replica)
    if not config["host"]:
        raise RuntimeError("DB_HOST no esta configurado")
    return pymysql.connect(**config)


def ensure_schema(conn):
    with conn.cursor() as cur:
        cur.execute(
            "CREATE TABLE IF NOT EXISTS visits ("
            " id INT AUTO_INCREMENT PRIMARY KEY,"
            " instance_id VARCHAR(64) NOT NULL,"
            " availability_zone VARCHAR(32) NOT NULL,"
            " created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)"
        )


def check_database(replica=False):
    started = time.perf_counter()
    try:
        conn = get_connection(replica)
        try:
            with conn.cursor() as cur:
                cur.execute("SELECT 1 AS ok")
                cur.fetchone()
        finally:
            conn.close()
        return {"ok": True, "latency_ms": round((time.perf_counter() - started) * 1000, 2)}
    except Exception as exc:  # noqa: BLE001 - se reporta cualquier fallo de conexion
        return {"ok": False, "error": type(exc).__name__}


def serialize_row(row):
    return {
        key: value.isoformat() if isinstance(value, datetime) else value
        for key, value in row.items()
    }


@app.get("/")
def index():
    meta = instance_metadata()
    return (
        "<!doctype html><html lang='es'><head><meta charset='utf-8'>"
        "<title>EF DGITI - AWS</title>"
        "<style>body{font-family:sans-serif;max-width:720px;margin:40px auto;padding:0 16px}"
        "code{background:#f2f2f2;padding:2px 6px;border-radius:4px}</style></head><body>"
        "<h1>Evaluacion Final DGITI - Servicio en AWS</h1>"
        f"<p>Atendido por la instancia <code>{meta['instance_id']}</code> "
        f"en la zona <code>{meta['availability_zone']}</code> "
        f"(version <code>{meta['version']}</code>).</p>"
        "<p>Recarga la pagina para ver como el balanceador reparte el trafico.</p>"
        "<ul><li><a href='/health'>/health</a></li><li><a href='/status'>/status</a></li>"
        "<li><a href='/api/info'>/api/info</a></li><li><a href='/api/visits'>/api/visits</a></li>"
        "</ul></body></html>"
    )


@app.get("/health")
def health():
    return jsonify(status="ok", **instance_metadata())


@app.get("/api/info")
def info():
    return jsonify(timestamp=datetime.now(timezone.utc).isoformat(), **instance_metadata())


@app.get("/status")
def status():
    primary = check_database(replica=False)
    replica = check_database(replica=True)
    healthy = primary["ok"]
    body = {
        "status": "ok" if healthy else "degraded",
        "database": {"primary": primary, "replica": replica},
        **instance_metadata(),
    }
    return jsonify(body), 200 if healthy else 503


@app.post("/api/visits")
def create_visit():
    meta = instance_metadata()
    try:
        conn = get_connection(replica=False)
        try:
            ensure_schema(conn)
            with conn.cursor() as cur:
                cur.execute(
                    "INSERT INTO visits (instance_id, availability_zone) VALUES (%s, %s)",
                    (meta["instance_id"], meta["availability_zone"]),
                )
                visit_id = cur.lastrowid
        finally:
            conn.close()
    except Exception as exc:  # noqa: BLE001
        return jsonify(error="database_unavailable", detail=type(exc).__name__), 503
    return jsonify(id=visit_id, written_to="primary", **meta), 201


@app.get("/api/visits")
def list_visits():
    query = (
        "SELECT id, instance_id, availability_zone, created_at "
        "FROM visits ORDER BY id DESC LIMIT 10"
    )
    rows, source = None, None
    for replica in (True, False):
        try:
            conn = get_connection(replica=replica)
            try:
                if not replica:
                    ensure_schema(conn)
                with conn.cursor() as cur:
                    cur.execute(query)
                    rows = cur.fetchall()
            finally:
                conn.close()
            source = "replica" if replica else "primary"
            break
        except Exception:  # noqa: BLE001 - si la replica falla se lee de la primaria
            continue
    if rows is None:
        return jsonify(error="database_unavailable"), 503
    return jsonify(
        read_from=source,
        visits=[serialize_row(row) for row in rows],
        **instance_metadata(),
    )


@app.get("/api/stress")
def stress():
    """Consume CPU durante `ms` milisegundos para provocar saturacion en la prueba de carga."""
    ms = request.args.get("ms", default=100, type=int)
    ms = max(1, min(ms if ms is not None else 100, MAX_STRESS_MS))
    deadline = time.perf_counter() + ms / 1000
    digest, iterations = b"dgiti", 0
    while time.perf_counter() < deadline:
        digest = hashlib.sha256(digest).digest()
        iterations += 1
    return jsonify(cpu_ms=ms, iterations=iterations, **instance_metadata())


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "8080")))
