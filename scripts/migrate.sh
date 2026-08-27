#!/usr/bin/env bash
#
# Upload the migrator and run it, synchronously.
set -euo pipefail

# One place that calls the API and says what happened when it goes wrong. `curl -sSf` prints a bare
# status code and discards the body, and the body is where the platform explains itself.
api() {
  local url="$1" payload="$2" max_time="${3:-}"
  local out curl_status status response

  # `--retry 0` is redundant with curl's default and deliberately explicit. This endpoint invokes
  # a migration synchronously: after a broken connection there is no safe way to know whether the
  # schema change ran, so a transport retry could execute a partially applied migration twice.
  set +e
  if [ -n "$max_time" ]; then
    out=$(curl -sS --retry 0 --max-time "$max_time" -X POST "$url" \
      -H "Authorization: Bearer ${SPROUTOS_TOKEN}" \
      -H 'Content-Type: application/json' \
      -d "$payload" \
      -w '\n%{http_code}')
  else
    out=$(curl -sS --retry 0 -X POST "$url" \
      -H "Authorization: Bearer ${SPROUTOS_TOKEN}" \
      -H 'Content-Type: application/json' \
      -d "$payload" \
      -w '\n%{http_code}')
  fi
  curl_status=$?
  set -e

  if [ "$curl_status" -ne 0 ]; then
    if [ "$curl_status" -eq 28 ] && [ "$max_time" = "900" ]; then
      echo "::error::The migration exceeded the 15-minute limit. Its final state may be partial;" >&2
      echo "::error::SproutOS did not retry it, and this action will not retry it." >&2
    else
      echo "::error::POST ${url} failed before a response was received (curl ${curl_status})." >&2
      echo "::error::The request was attempted once and was not retried." >&2
    fi
    return "$curl_status"
  fi

  status=$(printf '%s' "$out" | tail -n1)
  response=$(printf '%s' "$out" | sed '$d')
  if [ "$status" -lt 200 ] || [ "$status" -ge 300 ]; then
    echo "::error::POST ${url} returned ${status}" >&2
    echo "::error::${response}" >&2
    return 1
  fi
  printf '%s' "$response"
}

upload=$(api "${API_URL}/v1/deploy/upload-url" \
  "{\"project\":\"${PROJECT}\",\"digest\":\"${DIGEST}\",\"preset\":\"migration\"}")

url=$(echo "$upload" | python3 -c 'import sys,json;print(json.load(sys.stdin)["url"])')
key=$(echo "$upload" | python3 -c 'import sys,json;print(json.load(sys.stdin)["key"])')

curl -sSf --retry 0 -X PUT "$url" --upload-file "$ARCHIVE" \
  -H 'Content-Type: application/zip' > /dev/null
echo "uploaded"

body=$(MIGRATION_KEY="$key" python3 -c '
import json, os
body = {"migration_key": os.environ["MIGRATION_KEY"]}
# Sent only when set. An empty string is not "use the default", it is a value the API would have to
# reject — and rejecting a field the caller never filled in is a confusing way to fail.
for name, field in (("HANDLER", "migration_handler"), ("RUNTIME", "runtime")):
    value = os.environ.get(name, "")
    if value:
        body[field] = value
print(json.dumps(body))
')

# This is the only long-running request. Lambda cannot run beyond 900 seconds, and bounding the
# client too makes the action's contract independent of a runner's or proxy's default timeout.
result=$(api "${API_URL}/v1/deploy/migrate" "$body" 900)

ok=$(echo "$result" | python3 -c 'import sys,json;print(json.load(sys.stdin)["ok"])')
output=$(echo "$result" | python3 -c 'import sys,json;print(json.load(sys.stdin)["output"])')

{
  echo "output<<SPROUTOS_EOF"
  echo "$output"
  echo "SPROUTOS_EOF"
} >> "$GITHUB_OUTPUT"

{
  echo "### SproutOS migration"
  echo
  echo '```'
  echo "$output"
  echo '```'
} >> "$GITHUB_STEP_SUMMARY"

# The migrator's verdict decides the step, not the HTTP call's. The API answers 200 for a migration
# that failed — the call worked, the migration did not — and a workflow that treated that as success
# would deploy code against a schema that was never changed.
if [ "$ok" != "True" ] && [ "$ok" != "true" ]; then
  echo "::error::The migration failed. Nothing is retried automatically: re-running a partially" >&2
  echo "::error::applied schema change is how a recoverable failure becomes an unrecoverable one." >&2
  exit 1
fi

echo "migration applied"
