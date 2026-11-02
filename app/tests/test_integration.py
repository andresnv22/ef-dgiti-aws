"""Pruebas de integracion contra el servicio desplegado detras del ALB.

Se ejecutan solo si existe la variable APP_URL, por ejemplo:
    APP_URL=http://mi-alb-123.us-east-1.elb.amazonaws.com pytest -m integration
"""
import json
import os
import urllib.error
import urllib.request

import pytest

APP_URL = os.environ.get("APP_URL", "").rstrip("/")

pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(not APP_URL, reason="APP_URL no definida"),
]


def get_json(path, method="GET"):
    req = urllib.request.Request(f"{APP_URL}{path}", method=method)
    try:
        with urllib.request.urlopen(req, timeout=10) as response:
            return response.status, json.loads(response.read())
    except urllib.error.HTTPError as err:
        return err.code, json.loads(err.read() or b"{}")


def test_health_endpoint():
    code, body = get_json("/health")
    assert code == 200
    assert body["status"] == "ok"


def test_status_reports_database():
    code, body = get_json("/status")
    assert code == 200, body
    assert body["database"]["primary"]["ok"] is True


def test_write_primary_and_read_back():
    code, created = get_json("/api/visits", method="POST")
    assert code == 201, created
    code, listed = get_json("/api/visits")
    assert code == 200
    assert listed["read_from"] in ("replica", "primary")


def test_load_balancer_uses_multiple_instances():
    instances = {get_json("/api/info")[1]["instance_id"] for _ in range(30)}
    assert len(instances) >= 2, f"Solo respondio {instances}"
