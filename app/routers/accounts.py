import logging

from fastapi import APIRouter, Depends, Header, HTTPException, status
from fastapi.encoders import jsonable_encoder
from sqlalchemy.orm import Session

from app.database import get_db
from app.models import Account, IdempotencyKey, Transaction
from app.schemas import (
    AccountCreate,
    AccountResponse,
    BalanceResponse,
    TransactionRequest,
    TransactionResponse,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/accounts", tags=["accounts"])


@router.post("", response_model=AccountResponse, status_code=status.HTTP_201_CREATED)
def create_account(payload: AccountCreate, db: Session = Depends(get_db)) -> AccountResponse:
    """Create a new bank account with an opening balance."""
    account = Account(holder_name=payload.holder_name, balance=payload.opening_balance)
    db.add(account)
    db.commit()
    db.refresh(account)
    return account


@router.get("/{account_id}/balance", response_model=BalanceResponse)
def get_balance(account_id: int, db: Session = Depends(get_db)) -> BalanceResponse:
    """Get the current balance of an account."""
    account = db.get(Account, account_id)
    if account is None:
        raise HTTPException(status_code=404, detail="Account not found")
    return BalanceResponse(account_id=account.id, balance=account.balance)


def _persist_idempotency_key(
    db: Session,
    *,
    key: str,
    account_id: int,
    endpoint: str,
    request_amount,
    response_body: dict,
    status_code: int,
) -> None:
    db.add(
        IdempotencyKey(
            key=key,
            account_id=account_id,
            endpoint=endpoint,
            request_amount=request_amount,
            response_body=jsonable_encoder(response_body),
            status_code=status_code,
        )
    )


@router.post("/{account_id}/deposit", response_model=TransactionResponse)
def deposit(
    account_id: int,
    payload: TransactionRequest,
    idempotency_key: str | None = Header(default=None, alias="Idempotency-Key"),
    db: Session = Depends(get_db),
):
    """Deposit money into an account. Requires Idempotency-Key header."""
    if not idempotency_key:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Idempotency-Key header required",
        )

    try:
        amount = payload.amount
        existing = db.get(IdempotencyKey, idempotency_key)
        if existing is not None:
            if existing.endpoint != "deposit":
                raise HTTPException(
                    status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                    detail="Idempotency-Key reused on different endpoint",
                )
            if existing.request_amount != amount:
                raise HTTPException(
                    status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                    detail="Idempotency-Key reused with different request payload",
                )
            # Replay with stored payload and status.
            if existing.status_code == 200:
                return existing.response_body
            raise HTTPException(
                status_code=existing.status_code,
                detail=existing.response_body.get("detail", existing.response_body),
            )

        # Lock the account row for the duration of the transaction.
        account = (
            db.query(Account)
            .filter(Account.id == account_id)
            .with_for_update()
            .one_or_none()
        )
        if account is None:
            raise HTTPException(status_code=404, detail="Account not found")

        account.balance = account.balance + amount

        tx = Transaction(account_id=account_id, type="deposit", amount=amount)
        db.add(tx)
        db.flush()  # ensures tx.id is available

        response = TransactionResponse(
            account_id=account_id,
            type="deposit",
            amount=amount,
            new_balance=account.balance,
            transaction_id=tx.id,
        )
        response_dict = response.model_dump()

        _persist_idempotency_key(
            db,
            key=idempotency_key,
            account_id=account_id,
            endpoint="deposit",
            request_amount=amount,
            response_body=response_dict,
            status_code=200,
        )
        db.commit()

        logger.info(
            "deposit_success",
            extra={
                "account_id": account_id,
                "amount": str(amount),
                "new_balance": str(account.balance),
                "transaction_id": tx.id,
            },
        )
        return response
    except HTTPException:
        db.rollback()
        raise
    except Exception as e:
        db.rollback()
        raise HTTPException(status_code=500, detail="Internal server error") from e


@router.post("/{account_id}/withdraw", response_model=TransactionResponse)
def withdraw(
    account_id: int,
    payload: TransactionRequest,
    idempotency_key: str | None = Header(default=None, alias="Idempotency-Key"),
    db: Session = Depends(get_db),
):
    """Withdraw money from an account. Requires Idempotency-Key header. Returns 422 if insufficient funds."""
    if not idempotency_key:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Idempotency-Key header required",
        )

    try:
        amount = payload.amount
        existing = db.get(IdempotencyKey, idempotency_key)
        if existing is not None:
            if existing.endpoint != "withdraw":
                raise HTTPException(
                    status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                    detail="Idempotency-Key reused on different endpoint",
                )
            if existing.request_amount != amount:
                raise HTTPException(
                    status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                    detail="Idempotency-Key reused with different request payload",
                )
            if existing.status_code == 200:
                return existing.response_body
            raise HTTPException(
                status_code=existing.status_code,
                detail=existing.response_body.get("detail", existing.response_body),
            )

        account = (
            db.query(Account)
            .filter(Account.id == account_id)
            .with_for_update()
            .one_or_none()
        )
        if account is None:
            raise HTTPException(status_code=404, detail="Account not found")

        if account.balance < amount:
            error_payload = {"detail": "Insufficient funds"}
            _persist_idempotency_key(
                db,
                key=idempotency_key,
                account_id=account_id,
                endpoint="withdraw",
                request_amount=amount,
                response_body=error_payload,
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            )
            db.commit()
            raise HTTPException(status_code=422, detail="Insufficient funds")

        account.balance = account.balance - amount

        tx = Transaction(account_id=account_id, type="withdraw", amount=amount)
        db.add(tx)
        db.flush()

        response = TransactionResponse(
            account_id=account_id,
            type="withdraw",
            amount=amount,
            new_balance=account.balance,
            transaction_id=tx.id,
        )
        response_dict = response.model_dump()

        _persist_idempotency_key(
            db,
            key=idempotency_key,
            account_id=account_id,
            endpoint="withdraw",
            request_amount=amount,
            response_body=response_dict,
            status_code=200,
        )
        db.commit()

        logger.info(
            "withdraw_success",
            extra={
                "account_id": account_id,
                "amount": str(amount),
                "new_balance": str(account.balance),
                "transaction_id": tx.id,
            },
        )
        return response
    except HTTPException:
        db.rollback()
        raise
    except Exception as e:
        db.rollback()
        raise HTTPException(status_code=500, detail="Internal server error") from e
