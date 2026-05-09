#!/usr/bin/env bash
# Smoke test for the Banking API (HTTPS with self-signed cert).
# Usage: ./scripts/smoke_test.sh [BASE_URL]
# Requires: curl. jq is recommended for robust JSON replay comparison; without jq, use sed (flat JSON) and exact body string match for replay.
set -euo pipefail

DEFAULT_URL="https://banking-api-alb-1168095763.ap-southeast-1.elb.amazonaws.com"
BASE_URL="${1:-$DEFAULT_URL}"
BASE_URL="${BASE_URL%/}"

# Unique per run so repeat runs against the same DB do not reuse idempotency keys from earlier smoke tests.
SMOKE_NONCE="${RANDOM}${RANDOM}"
SMOKE_NONCE="${SMOKE_NONCE:0:8}"

TOTAL=10
TMP_DIR=""
cleanup() {
  [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]] && rm -rf "${TMP_DIR}"
}
trap cleanup EXIT
TMP_DIR="$(mktemp -d)"

curl_json() {
  local method="$1"
  local path="$2"
  shift 2
  local out="${TMP_DIR}/body"
  local code
  code="$(curl -k -g -sS -o "${out}" -w "%{http_code}" -X "${method}" "$@" "${BASE_URL}${path}")"
  printf '%s' "${code}"
}

curl_post_json() {
  local path="$1"
  local body="$2"
  shift 2
  local f="${TMP_DIR}/post.$$.$RANDOM.json"
  printf '%s' "${body}" >"${f}"
  local out="${TMP_DIR}/body"
  local code
  code="$(curl -k -g -sS -o "${out}" -w "%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    "$@" \
    --data-binary "@${f}" \
    "${BASE_URL}${path}")"
  rm -f "${f}"
  printf '%s' "${code}"
}

read_body() {
  cat "${TMP_DIR}/body"
}

json_get() {
  local key="$1"
  local json="$2"
  if command -v jq >/dev/null 2>&1; then
    echo "${json}" | jq -r ".${key} // empty"
  else
    echo "${json}" | tr -d '\n' | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p; t; s/.*\"${key}\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" | head -1
  fi
}

decimal_eq() {
  awk -v x="$1" -v y="$2" 'BEGIN { if (x == "" || y == "") exit 1; if ((x + 0) == (y + 0)) exit 0; exit 1 }'
}

deposit_replay_eq() {
  local a="$1" b="$2"
  if command -v jq >/dev/null 2>&1; then
    [[ "$(echo "${a}" | jq -c -S .)" == "$(echo "${b}" | jq -c -S .)" ]]
  else
    local k
    for k in account_id type amount new_balance transaction_id; do
      local va vb
      va="$(json_get "${k}" "${a}")"
      vb="$(json_get "${k}" "${b}")"
      if [[ "${k}" == "amount" || "${k}" == "new_balance" ]]; then
        decimal_eq "${va}" "${vb}" || return 1
      else
        [[ "${va}" == "${vb}" ]] || return 1
      fi
    done
  fi
}

fail() {
  echo "$1" >&2
  exit 1
}

# --- [1/10] Health ---
code="$(curl_json GET "/health")"
body="$(read_body)"
if [[ "${code}" != "200" ]] || ! echo "${body}" | grep -q '"status"[[:space:]]*:[[:space:]]*"ok"'; then
  echo "Actual HTTP ${code} body: ${body}" >&2
  fail "[1/${TOTAL}] Health check ... FAIL"
fi
echo "[1/${TOTAL}] Health check ... PASS"

# --- [2/10] Version ---
code="$(curl_json GET "/version")"
body="$(read_body)"
if [[ "${code}" != "200" ]]; then
  echo "Actual HTTP ${code} body: ${body}" >&2
  fail "[2/${TOTAL}] Version check ... FAIL"
fi
echo "Version response: ${body}"
ver="$(json_get version "${body}")"
echo "[2/${TOTAL}] Version check ... PASS (sha=${ver})"

# --- [3/10] Create account ---
code="$(curl_post_json "/accounts" '{"holder_name": "Smoke Test User", "opening_balance": 1000}')"
body="$(read_body)"
if [[ "${code}" != "201" ]]; then
  echo "Actual HTTP ${code} body: ${body}" >&2
  fail "[3/${TOTAL}] Create account ... FAIL"
fi
ACCOUNT_ID="$(json_get id "${body}")"
if [[ -z "${ACCOUNT_ID}" || "${ACCOUNT_ID}" == "null" ]]; then
  echo "Could not parse account id from: ${body}" >&2
  fail "[3/${TOTAL}] Create account ... FAIL"
fi
echo "[3/${TOTAL}] Create account ... PASS (id=${ACCOUNT_ID})"

# --- [4/10] Get balance ---
code="$(curl_json GET "/accounts/${ACCOUNT_ID}/balance")"
body="$(read_body)"
bal="$(json_get balance "${body}")"
if [[ "${code}" != "200" ]] || ! decimal_eq "${bal}" 1000; then
  echo "Actual HTTP ${code} body: ${body}" >&2
  fail "[4/${TOTAL}] Get balance ... FAIL"
fi
echo "[4/${TOTAL}] Get balance ... PASS"

# --- [5/10] Deposit ---
code="$(curl_post_json "/accounts/${ACCOUNT_ID}/deposit" '{"amount": 500}' \
  -H "Idempotency-Key: smoke-deposit-1-${SMOKE_NONCE}")"
body="$(read_body)"
nb="$(json_get new_balance "${body}")"
if [[ "${code}" != "200" ]] || ! decimal_eq "${nb}" 1500; then
  echo "Actual HTTP ${code} body: ${body}" >&2
  fail "[5/${TOTAL}] Deposit ... FAIL"
fi
DEPOSIT_BODY_1="${body}"
echo "[5/${TOTAL}] Deposit ... PASS"

# --- [6/10] Idempotency replay ---
code="$(curl_post_json "/accounts/${ACCOUNT_ID}/deposit" '{"amount": 500}' \
  -H "Idempotency-Key: smoke-deposit-1-${SMOKE_NONCE}")"
body="$(read_body)"
nb="$(json_get new_balance "${body}")"
if [[ "${code}" != "200" ]]; then
  echo "Actual HTTP ${code} body: ${body}" >&2
  fail "[6/${TOTAL}] Idempotency replay ... FAIL"
fi
if ! deposit_replay_eq "${DEPOSIT_BODY_1}" "${body}"; then
  echo "Replay response differs. First: ${DEPOSIT_BODY_1} Second: ${body}" >&2
  fail "[6/${TOTAL}] Idempotency replay ... FAIL"
fi
if ! decimal_eq "${nb}" 1500; then
  echo "Unexpected new_balance after replay: ${body}" >&2
  fail "[6/${TOTAL}] Idempotency replay ... FAIL"
fi
echo "[6/${TOTAL}] Idempotency replay ... PASS"

# --- [7/10] Idempotency conflict ---
code="$(curl_post_json "/accounts/${ACCOUNT_ID}/deposit" '{"amount": 999}' \
  -H "Idempotency-Key: smoke-deposit-1-${SMOKE_NONCE}")"
body="$(read_body)"
if [[ "${code}" != "422" ]]; then
  echo "Actual HTTP ${code} body: ${body}" >&2
  fail "[7/${TOTAL}] Idempotency conflict ... FAIL"
fi
echo "[7/${TOTAL}] Idempotency conflict ... PASS"

# --- [8/10] Withdraw ---
code="$(curl_post_json "/accounts/${ACCOUNT_ID}/withdraw" '{"amount": 200}' \
  -H "Idempotency-Key: smoke-withdraw-1-${SMOKE_NONCE}")"
body="$(read_body)"
nb="$(json_get new_balance "${body}")"
if [[ "${code}" != "200" ]] || ! decimal_eq "${nb}" 1300; then
  echo "Actual HTTP ${code} body: ${body}" >&2
  fail "[8/${TOTAL}] Withdraw ... FAIL"
fi
echo "[8/${TOTAL}] Withdraw ... PASS"

# --- [9/10] Insufficient funds ---
code="$(curl_post_json "/accounts/${ACCOUNT_ID}/withdraw" '{"amount": 999999}' \
  -H "Idempotency-Key: smoke-withdraw-fail-${SMOKE_NONCE}")"
body="$(read_body)"
if [[ "${code}" != "422" ]]; then
  echo "Actual HTTP ${code} body: ${body}" >&2
  fail "[9/${TOTAL}] Insufficient funds ... FAIL"
fi
if [[ -z "${body}" ]]; then
  echo "Actual HTTP 422 body: (empty)" >&2
  fail "[9/${TOTAL}] Insufficient funds ... FAIL"
fi
if ! echo "${body}" | grep -q 'Insufficient funds'; then
  echo "Expected Insufficient funds in body: ${body}" >&2
  fail "[9/${TOTAL}] Insufficient funds ... FAIL"
fi
echo "[9/${TOTAL}] Insufficient funds ... PASS"

# --- [10/10] Final balance ---
code="$(curl_json GET "/accounts/${ACCOUNT_ID}/balance")"
body="$(read_body)"
bal="$(json_get balance "${body}")"
if [[ "${code}" != "200" ]] || ! decimal_eq "${bal}" 1300; then
  echo "Actual HTTP ${code} body: ${body}" >&2
  fail "[10/${TOTAL}] Final balance check ... FAIL"
fi
echo "[10/${TOTAL}] Final balance check ... PASS"

echo "All ${TOTAL} checks passed"
