#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${HERE}/../lib/rate-limit.sh"

# shellcheck source=lib/rate-limit.sh
. "${LIB}"

# Test rate_limit_check parses headers correctly
test_rate_limit_check() {
  # Normal case: plenty of remaining
  headers="X-RateLimit-Limit: 5000
X-RateLimit-Remaining: 4999
X-RateLimit-Reset: $(($(date +%s) + 3600))"
  rate_limit_check "${headers}"
  [[ "${RATE_LIMIT_REMAINING}" -eq 4999 ]]
  [[ "${RATE_LIMIT_RESET}" -gt $(date +%s) ]]
  [[ -z "${RATE_LIMIT_RETRY_AFTER:-}" ]]

  # Rate limited: Retry-After present
  headers="X-RateLimit-Limit: 5000
X-RateLimit-Remaining: 0
X-RateLimit-Reset: $(($(date +%s) + 3600))
Retry-After: 60"
  rate_limit_check "${headers}"
  [[ "${RATE_LIMIT_REMAINING}" -eq 0 ]]
  [[ "${RATE_LIMIT_RETRY_AFTER}" -eq 60 ]]

  # Missing headers (should not crash)
  headers=""
  rate_limit_check "${headers}"
  [[ "${RATE_LIMIT_REMAINING}" -eq 5000 ]]  # default assumption
  [[ -z "${RATE_LIMIT_RETRY_AFTER:-}" ]]

  echo "rate_limit_check tests passed"
}

# Test rate_limit_backoff calculates exponential backoff
test_rate_limit_backoff() {
  # Attempt 0 -> 1s
  [[ "$(rate_limit_backoff 0)" == "1" ]]

  # Attempt 1 -> 2s
  [[ "$(rate_limit_backoff 1)" == "2" ]]

  # Attempt 2 -> 4s
  [[ "$(rate_limit_backoff 2)" == "4" ]]

  # Attempt 3 -> 8s
  [[ "$(rate_limit_backoff 3)" == "8" ]]

  # Attempt 4 -> 16s
  [[ "$(rate_limit_backoff 4)" == "16" ]]

  # Attempt 5 -> 32s
  [[ "$(rate_limit_backoff 5)" == "32" ]]

  # Attempt 6 -> 60s (capped)
  [[ "$(rate_limit_backoff 6)" == "60" ]]

  # Attempt 10 -> 60s (capped)
  [[ "$(rate_limit_backoff 10)" == "60" ]]

  echo "rate_limit_backoff tests passed"
}

# Test rate_limit_poll_sleep returns a value in range
test_rate_limit_poll_sleep() {
  export RATE_LIMIT_TEST_MODE=1

  rate_limit_poll_sleep 10 60
  [[ "${POLL_SLEEP_SECONDS}" -ge 10 ]]
  [[ "${POLL_SLEEP_SECONDS}" -le 60 ]]

  rate_limit_poll_sleep 30 3600
  [[ "${POLL_SLEEP_SECONDS}" -ge 30 ]]
  [[ "${POLL_SLEEP_SECONDS}" -le 3600 ]]

  unset RATE_LIMIT_TEST_MODE

  echo "rate_limit_poll_sleep tests passed"
}

# Run tests
test_rate_limit_check
test_rate_limit_backoff
test_rate_limit_poll_sleep

echo "All rate-limit tests passed"