#!/usr/bin/env bash
# Rate limit handling utilities for GitHub API
# Provides functions to parse rate limit headers, calculate backoff, and sleep with jitter

set -euo pipefail

# Parse GitHub API rate limit headers
# Sets global variables: RATE_LIMIT_REMAINING, RATE_LIMIT_RESET, RATE_LIMIT_RETRY_AFTER
# Args: $1 = headers string (newline-separated)
rate_limit_check() {
  local headers="${1:-}"
  local remaining=5000
  local reset=0
  local retry_after=""

  while IFS= read -r line; do
    case "${line}" in
      X-RateLimit-Remaining:*)
        remaining="${line#*: }"
        remaining="${remaining//[^0-9]/}"
        ;;
      X-RateLimit-Reset:*)
        reset="${line#*: }"
        reset="${reset//[^0-9]/}"
        ;;
      Retry-After:*)
        retry_after="${line#*: }"
        retry_after="${retry_after//[^0-9]/}"
        ;;
    esac
  done <<< "${headers}"

  RATE_LIMIT_REMAINING="${remaining}"
  RATE_LIMIT_RESET="${reset}"
  RATE_LIMIT_RETRY_AFTER="${retry_after}"
}

# Calculate exponential backoff in seconds and print it.
# Args: $1 = attempt number (0-based). Cap at 60 seconds.
rate_limit_backoff() {
  local attempt="${1:-0}"
  local backoff=1

  for ((i = 0; i < attempt; i++)); do
    backoff=$((backoff * 2))
    if [[ ${backoff} -gt 60 ]]; then
      backoff=60
      break
    fi
  done

  printf '%s\n' "${backoff}"
}

# Sleep with jitter for polling intervals
# Args: $1 = min seconds, $2 = max seconds
# Sets global: POLL_SLEEP_SECONDS
# If RATE_LIMIT_TEST_MODE=1, only calculates without sleeping
rate_limit_poll_sleep() {
  local min="${1:-30}"
  local max="${2:-3600}"
  local range=$((max - min + 1))
  local jitter=0

  if [[ ${range} -gt 0 ]]; then
    jitter=$((RANDOM % range))
  fi

  POLL_SLEEP_SECONDS=$((min + jitter))

  if [[ "${RATE_LIMIT_TEST_MODE:-0}" != "1" ]]; then
    sleep "${POLL_SLEEP_SECONDS}"
  fi
}

# Wait for rate limit to reset or retry-after
# Args: $1 = headers string
# Returns 0 when ready to proceed, non-zero on error
rate_limit_wait() {
  local headers="${1:-}"
  rate_limit_check "${headers}"

  if [[ -n "${RATE_LIMIT_RETRY_AFTER:-}" ]]; then
    sleep "${RATE_LIMIT_RETRY_AFTER}"
    return 0
  fi

  if [[ ${RATE_LIMIT_REMAINING} -gt 0 ]]; then
    return 0
  fi

  local now
  now=$(date +%s)
  local wait_time=$((RATE_LIMIT_RESET - now + 1))

  if [[ ${wait_time} -gt 0 ]]; then
    sleep "${wait_time}"
  fi

  return 0
}