#!/usr/bin/env bash
# Exercise the action's dangerous boundary with a fake HTTP client: success, a migration-declared
# failure, and an ambiguous timeout. Every case must make exactly one migration request.
set -euo pipefail

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

mkdir -p "$test_tmp/bin"
cat > "$test_tmp/bin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail

printf '%q ' "$@" >> "$FAKE_CURL_LOG"
printf '\n' >> "$FAKE_CURL_LOG"

args=" $* "
if [[ "$args" == *"/v1/deploy/upload-url"* ]]; then
  printf '{"url":"https://upload.example/migrator","key":"migrations/test.zip"}\n200'
elif [[ "$args" == *" -X PUT "* ]]; then
  exit 0
elif [[ "$args" == *"/v1/deploy/migrate"* ]]; then
  printf 'request\n' >> "$FAKE_MIGRATE_CALLS"
  case "${FAKE_RESULT:-success}" in
    success) printf '{"ok":true,"output":"migration complete"}\n200' ;;
    failure) printf '{"ok":false,"output":"migration refused"}\n200' ;;
    timeout) exit 28 ;;
    *) echo "unknown FAKE_RESULT" >&2; exit 2 ;;
  esac
else
  echo "unexpected curl invocation: $*" >&2
  exit 2
fi
FAKE_CURL
chmod +x "$test_tmp/bin/curl"

export PATH="$test_tmp/bin:$PATH"
export FAKE_CURL_LOG="$test_tmp/curl.log"
export FAKE_MIGRATE_CALLS="$test_tmp/migrate.calls"
export API_URL=https://api.example
export SPROUTOS_TOKEN=test-token
export ARCHIVE="$test_tmp/migrator.zip"
export DIGEST=0123456789abcdef
export PROJECT=test-project
export HANDLER=index.handler
export RUNTIME=nodejs22.x
export GITHUB_OUTPUT="$test_tmp/output"
export GITHUB_STEP_SUMMARY="$test_tmp/summary"
touch "$ARCHIVE"

assert_one_migration_call() {
  [ "$(wc -l < "$FAKE_MIGRATE_CALLS" | tr -d ' ')" = "1" ] || {
    echo "migration endpoint was not called exactly once" >&2
    exit 1
  }
}

: > "$FAKE_CURL_LOG"
: > "$FAKE_MIGRATE_CALLS"
FAKE_RESULT=success ./scripts/migrate.sh
assert_one_migration_call
grep -q -- '--max-time 900' "$FAKE_CURL_LOG"
[ "$(grep -c -- '--retry 0' "$FAKE_CURL_LOG")" = "3" ]
grep -q 'migration complete' "$GITHUB_OUTPUT"

: > "$FAKE_CURL_LOG"
: > "$FAKE_MIGRATE_CALLS"
if FAKE_RESULT=failure ./scripts/migrate.sh > "$test_tmp/failure.out" 2>&1; then
  echo "a migration-declared failure was accepted" >&2
  exit 1
fi
assert_one_migration_call
grep -q 'Nothing is retried automatically' "$test_tmp/failure.out"

: > "$FAKE_CURL_LOG"
: > "$FAKE_MIGRATE_CALLS"
if FAKE_RESULT=timeout ./scripts/migrate.sh > "$test_tmp/timeout.out" 2>&1; then
  echo "a migration timeout was accepted" >&2
  exit 1
fi
assert_one_migration_call
grep -q 'exceeded the 15-minute limit' "$test_tmp/timeout.out"
grep -q 'will not retry it' "$test_tmp/timeout.out"

echo "migration action contract passes"
