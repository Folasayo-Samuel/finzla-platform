"""Verify environment-dependent behaviour: prod hardening and the 503 path.

Run from the app/ directory:  PYTHONPATH=. python tests/verify_behaviour.py
Not collected by pytest (no test_ prefix) because it re-imports the app
module with different environment variables, which pytest-xdist dislikes.
"""

import importlib
import os
import sys

from fastapi.testclient import TestClient

failures = []


def check(env, expect, label):
    for k in ("APP_ENV", "SIMULATE_UNHEALTHY"):
        os.environ.pop(k, None)
    os.environ.update(env)
    sys.modules.pop("src.main", None)
    m = importlib.import_module("src.main")
    c = TestClient(m.app)
    print(f"{label}:")
    for path, code in expect:
        r = c.get(path)
        ok = r.status_code == code
        if not ok:
            failures.append((label, path, r.status_code, code))
        print(f"  {'OK  ' if ok else 'FAIL'} {path:16} -> {r.status_code} (want {code})")


check(
    {"APP_ENV": "prod"},
    [("/health", 200), ("/docs", 404), ("/openapi.json", 404)],
    "prod hardening (OpenAPI must be disabled)",
)
check(
    {"APP_ENV": "dev"},
    [("/health", 200), ("/docs", 200), ("/openapi.json", 200)],
    "dev (docs available)",
)
check(
    {"APP_ENV": "dev", "SIMULATE_UNHEALTHY": "true"},
    [("/health", 503)],
    "unhealthy simulation (drives the rollback demo)",
)

print()
if failures:
    print("FAILURES:", failures)
    sys.exit(1)
print("ALL BEHAVIOURAL CHECKS PASSED")
