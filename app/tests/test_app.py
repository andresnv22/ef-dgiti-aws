"""Pruebas unitarias: la base de datos se reemplaza por dobles de prueba."""
from datetime import datetime

import pytest

import app as app_module


class FakeCursor:
    def __init__(self, rows=None):
        self.rows = rows or []
        self.executed = []
        self.lastrowid = 42

    def execute(self, sql, params=None):
        self.executed.append((sql, params))

    def fetchone(self):
        return {"ok": 1}

    def fetchall(self):
        return self.rows

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


class FakeConnection:
    def __init__(self, rows=None):
        self.cursor_obj = FakeCursor(rows)
        self.closed = False

    def cursor(self):
        return self.cursor_obj

    def close(self):
        self.closed = True


@pytest.fixture
def client(monkeypatch):
    monkeypatch.setenv("INSTANCE_ID", "i-test123")
    monkeypatch.setenv("AVAILABILITY_ZONE", "us-east-1a")
    monkeypatch.setenv("APP_VERSION", "9.9.9")
    app_module.app.config["TESTING"] = True
    return app_module.app.test_client()


def test_health_ok(client):
    response = client.get("/health")
    assert response.status_code == 200
    body = response.get_json()
    assert body["status"] == "ok"
    assert body["instance_id"] == "i-test123"
    assert body["availability_zone"] == "us-east-1a"


def test_info_returns_instance_and_version(client):
    body = client.get("/api/info").get_json()
    assert body["version"] == "9.9.9"
    assert body["instance_id"] == "i-test123"
    assert "timestamp" in body


def test_index_shows_instance(client):
    response = client.get("/")
    assert response.status_code == 200
    assert b"i-test123" in response.data


def test_status_ok_when_primary_and_replica_respond(client, monkeypatch):
    monkeypatch.setattr(app_module, "get_connection", lambda replica=False: FakeConnection())
    response = client.get("/status")
    assert response.status_code == 200
    body = response.get_json()
    assert body["database"]["primary"]["ok"] is True
    assert body["database"]["replica"]["ok"] is True


def test_status_503_when_database_down(client, monkeypatch):
    def broken(replica=False):
        raise ConnectionError("sin conexion")

    monkeypatch.setattr(app_module, "get_connection", broken)
    response = client.get("/status")
    assert response.status_code == 503
    assert response.get_json()["status"] == "degraded"


def test_create_visit_writes_to_primary(client, monkeypatch):
    calls = []
    conn = FakeConnection()

    def fake_connection(replica=False):
        calls.append(replica)
        return conn

    monkeypatch.setattr(app_module, "get_connection", fake_connection)
    response = client.post("/api/visits")
    assert response.status_code == 201
    assert response.get_json()["id"] == 42
    assert calls == [False]
    assert conn.closed
    insert_sql, params = conn.cursor_obj.executed[-1]
    assert insert_sql.startswith("INSERT INTO visits")
    assert params == ("i-test123", "us-east-1a")


def test_list_visits_reads_from_replica(client, monkeypatch):
    rows = [{"id": 1, "instance_id": "i-a", "availability_zone": "us-east-1b",
             "created_at": datetime(2026, 11, 2, 10, 0, 0)}]
    monkeypatch.setattr(app_module, "get_connection",
                        lambda replica=False: FakeConnection(rows))
    body = client.get("/api/visits").get_json()
    assert body["read_from"] == "replica"
    assert body["visits"][0]["created_at"] == "2026-11-02T10:00:00"


def test_list_visits_falls_back_to_primary(client, monkeypatch):
    def replica_down(replica=False):
        if replica:
            raise ConnectionError("replica caida")
        return FakeConnection([])

    monkeypatch.setattr(app_module, "get_connection", replica_down)
    body = client.get("/api/visits").get_json()
    assert body["read_from"] == "primary"


def test_visits_503_when_database_down(client, monkeypatch):
    def broken(replica=False):
        raise ConnectionError("sin conexion")

    monkeypatch.setattr(app_module, "get_connection", broken)
    assert client.post("/api/visits").status_code == 503
    assert client.get("/api/visits").status_code == 503


@pytest.mark.parametrize("requested, expected", [("10", 10), ("0", 1), ("99999", 2000)])
def test_stress_clamps_cpu_time(client, monkeypatch, requested, expected):
    # Se acelera el reloj para que la prueba no consuma CPU real.
    ticks = iter(range(0, 10_000_000, 500))
    monkeypatch.setattr(app_module.time, "perf_counter", lambda: next(ticks) / 1000)
    body = client.get(f"/api/stress?ms={requested}").get_json()
    assert body["cpu_ms"] == expected
    assert body["iterations"] >= 0


def test_db_config_uses_replica_host(monkeypatch):
    monkeypatch.setenv("DB_HOST", "primary.local")
    monkeypatch.setenv("DB_REPLICA_HOST", "replica.local")
    assert app_module.db_config(replica=False)["host"] == "primary.local"
    assert app_module.db_config(replica=True)["host"] == "replica.local"


def test_get_connection_requires_host(monkeypatch):
    monkeypatch.delenv("DB_HOST", raising=False)
    monkeypatch.delenv("DB_REPLICA_HOST", raising=False)
    with pytest.raises(RuntimeError):
        app_module.get_connection()


def test_unknown_route_returns_404(client):
    assert client.get("/no-existe").status_code == 404
