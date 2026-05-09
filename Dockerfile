FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app
COPY tests ./tests
COPY alembic ./alembic
COPY alembic.ini ./alembic.ini

EXPOSE 8000

ARG APP_VERSION=unknown
ARG BUILD_TIME=unknown
ENV APP_VERSION=${APP_VERSION}
ENV BUILD_TIME=${BUILD_TIME}

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
