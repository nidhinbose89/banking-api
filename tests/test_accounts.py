import os
from decimal import Decimal

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, text
from sqlalchemy.engine.url import make_url
from sqlalchemy.orm import sessionmaker

from app.database import Base, get_db
from app.main import app

# Ensure models are registered on Base.metadata
import app.models as _models  # noqa: F401


def _decimal_from_json(value) -> Decimal:
    # FastAPI/Pydantic may serialize Decimal as either number or string.
    return Decimal(str(value))


@pytest.fixture(scope="session")
def test_engine():
    database_url = os.environ["DATABASE_URL"]
    url = make_url(database_url)
    test_db_url = url.set(database="banking_test")
    admin_db_url = url.set(database="postgres")

    admin_engine = create_engine(admin_db_url)
    with admin_engine.connect().execution_options(isolation_level="AUTOCOMMIT") as conn:
        exists = conn.execute(
            text("SELECT 1 FROM pg_database WHERE datname=:name"),
            {"name": "banking_test"},
        ).first()
        if not exists:
            conn.execute(text("CREATE DATABASE banking_test"))

    engine = create_engine(test_db_url)
    return engine


@pytest.fixture
def client(test_engine):
    TestingSessionLocal = sessionmaker(
        autocommit=False, autoflush=False, bind=test_engine
    )

    # Fresh schema per test.
    Base.metadata.drop_all(bind=test_engine)
    Base.metadata.create_all(bind=test_engine)

    def override_get_db():
        db = TestingSessionLocal()
        try:
            yield db
        finally:
            db.close()

    app.dependency_overrides[get_db] = override_get_db

    with TestClient(app) as c:
        yield c

    Base.metadata.drop_all(bind=test_engine)
    app.dependency_overrides.pop(get_db, None)


def _create_account(client: TestClient, holder_name: str, opening_balance=1000):
    resp = client.post(
        "/accounts",
        json={"holder_name": holder_name, "opening_balance": opening_balance},
    )
    assert resp.status_code == 201
    return resp


def test_create_account(client: TestClient):
    resp = _create_account(client, "Alice", 1000)
    data = resp.json()
    assert data["holder_name"] == "Alice"
    assert _decimal_from_json(data["balance"]) == Decimal("1000")
    assert "id" in data and isinstance(data["id"], int)
    assert "created_at" in data


def test_create_account_invalid_name(client: TestClient):
    resp = client.post(
        "/accounts",
        json={"holder_name": "", "opening_balance": 0},
    )
    assert resp.status_code == 422


def test_get_balance(client: TestClient):
    resp = _create_account(client, "Alice", 1000).json()
    account_id = resp["id"]

    bal = client.get(f"/accounts/{account_id}/balance")
    assert bal.status_code == 200
    data = bal.json()
    assert data["account_id"] == account_id
    assert _decimal_from_json(data["balance"]) == Decimal("1000")


def test_get_balance_not_found(client: TestClient):
    resp = client.get("/accounts/999999/balance")
    assert resp.status_code == 404
    assert resp.json()["detail"] == "Account not found"


def test_deposit_success(client: TestClient):
    account_id = _create_account(client, "Alice", 1000).json()["id"]

    resp = client.post(
        f"/accounts/{account_id}/deposit",
        headers={"Idempotency-Key": "deposit-1"},
        json={"amount": 500},
    )
    assert resp.status_code == 200
    data = resp.json()
    assert data["account_id"] == account_id
    assert data["type"] == "deposit"
    assert _decimal_from_json(data["amount"]) == Decimal("500")
    assert _decimal_from_json(data["new_balance"]) == Decimal("1500")
    assert isinstance(data["transaction_id"], int)


def test_deposit_missing_idempotency_key(client: TestClient):
    account_id = _create_account(client, "Alice", 1000).json()["id"]
    resp = client.post(
        f"/accounts/{account_id}/deposit",
        json={"amount": 500},
    )
    assert resp.status_code == 400
    assert resp.json()["detail"] == "Idempotency-Key header required"


def test_deposit_idempotent_replay(client: TestClient):
    account_id = _create_account(client, "Alice", 1000).json()["id"]

    resp1 = client.post(
        f"/accounts/{account_id}/deposit",
        headers={"Idempotency-Key": "idem-deposit"},
        json={"amount": 500},
    )
    assert resp1.status_code == 200
    data1 = resp1.json()

    resp2 = client.post(
        f"/accounts/{account_id}/deposit",
        headers={"Idempotency-Key": "idem-deposit"},
        json={"amount": 500},
    )
    assert resp2.status_code == 200
    data2 = resp2.json()

    # Decimal serialization might differ in formatting; compare semantically.
    assert data2["account_id"] == data1["account_id"]
    assert data2["type"] == data1["type"]
    assert data2["transaction_id"] == data1["transaction_id"]
    assert _decimal_from_json(data2["amount"]) == _decimal_from_json(data1["amount"])
    assert _decimal_from_json(data2["new_balance"]) == _decimal_from_json(data1["new_balance"])

    bal = client.get(f"/accounts/{account_id}/balance").json()
    assert _decimal_from_json(bal["balance"]) == Decimal("1500")


def test_deposit_idempotency_key_reused_with_different_amount(client: TestClient):
    account_id = _create_account(client, "Alice", 1000).json()["id"]

    first = client.post(
        f"/accounts/{account_id}/deposit",
        headers={"Idempotency-Key": "idem-diff-amount"},
        json={"amount": 500},
    )
    assert first.status_code == 200

    replay_different_payload = client.post(
        f"/accounts/{account_id}/deposit",
        headers={"Idempotency-Key": "idem-diff-amount"},
        json={"amount": 700},
    )
    assert replay_different_payload.status_code == 422
    assert replay_different_payload.json()["detail"] == (
        "Idempotency-Key reused with different request payload"
    )


def test_deposit_negative_amount(client: TestClient):
    account_id = _create_account(client, "Alice", 1000).json()["id"]
    resp = client.post(
        f"/accounts/{account_id}/deposit",
        headers={"Idempotency-Key": "deposit-negative"},
        json={"amount": -100},
    )
    assert resp.status_code == 422


def test_withdraw_success(client: TestClient):
    account_id = _create_account(client, "Alice", 1500).json()["id"]
    resp = client.post(
        f"/accounts/{account_id}/withdraw",
        headers={"Idempotency-Key": "withdraw-1"},
        json={"amount": 200},
    )
    assert resp.status_code == 200
    data = resp.json()
    assert data["type"] == "withdraw"
    assert _decimal_from_json(data["amount"]) == Decimal("200")
    assert _decimal_from_json(data["new_balance"]) == Decimal("1300")
    assert isinstance(data["transaction_id"], int)


def test_withdraw_insufficient_funds(client: TestClient):
    account_id = _create_account(client, "Alice", 1000).json()["id"]
    resp = client.post(
        f"/accounts/{account_id}/withdraw",
        headers={"Idempotency-Key": "withdraw-oom"},
        json={"amount": 99999},
    )
    assert resp.status_code == 422
    assert resp.json()["detail"] == "Insufficient funds"


def test_withdraw_idempotent_replay_on_failure(client: TestClient):
    account_id = _create_account(client, "Alice", 1000).json()["id"]

    resp1 = client.post(
        f"/accounts/{account_id}/withdraw",
        headers={"Idempotency-Key": "withdraw-oom-idem"},
        json={"amount": 99999},
    )
    assert resp1.status_code == 422
    data1 = resp1.json()

    resp2 = client.post(
        f"/accounts/{account_id}/withdraw",
        headers={"Idempotency-Key": "withdraw-oom-idem"},
        json={"amount": 99999},
    )
    assert resp2.status_code == 422
    data2 = resp2.json()
    assert data1 == data2

    bal = client.get(f"/accounts/{account_id}/balance").json()
    assert _decimal_from_json(bal["balance"]) == Decimal("1000")

