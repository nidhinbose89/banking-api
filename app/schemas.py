from datetime import datetime
from decimal import Decimal

from pydantic import BaseModel, ConfigDict, Field


class AccountCreate(BaseModel):
    holder_name: str = Field(min_length=1, max_length=100)
    opening_balance: Decimal = Field(default=Decimal("0"), ge=0)


class AccountResponse(BaseModel):
    id: int
    holder_name: str
    balance: Decimal
    created_at: datetime

    model_config = ConfigDict(from_attributes=True)


class BalanceResponse(BaseModel):
    account_id: int
    balance: Decimal


class TransactionRequest(BaseModel):
    amount: Decimal = Field(gt=0)


class TransactionResponse(BaseModel):
    account_id: int
    type: str
    amount: Decimal
    new_balance: Decimal
    transaction_id: int
