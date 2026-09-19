#!/usr/bin/env bash
# Create a verified commit on a branch through the GitHub GraphQL API using the
# GitHub App installation token. Commits created with createCommitOnBranch are
# committed by GitHub and signed with GitHub's verified signature, so they carry
# the green "Verified" badge and satisfy branch rules such as
# "Commits must have verified signatures".
#
# Usage:
#   bash gh-app/api-commit.sh <owner>/<repo> <branch> \
#     -m "<message>" [--file <path>=<content-or-@path>] ...
#
# A file's content may be given inline (path=content) or as @file (path=@file).
# All files are committed in a single commit; the author identity is the App
# (conahcnuj[bot]) and the committer is GitHub.com.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${DIR}/app.env"
if [[ ! -f "${ENV_FILE}" && -f "${DIR}/app.env.example" ]]; then
  ENV_FILE="${DIR}/app.env.example"
fi

set -a
. "${ENV_FILE}"
set +a

API_BASE="${GH_APP_API_BASE:-https://api.github.com}"
GRAPHQL="${API_BASE}/graphql"

if [[ $# -lt 3 ]]; then
  echo "Usage: bash gh-app/api-commit.sh <owner>/<repo> <branch> -m <message> [--file <path>=<content|@path>] ..." >&2
  exit 1
fi

REPO="${1}"
BRANCH="${2}"
shift 2

MESSAGE=""
declare -a FILE_SPECS=()
while [[ $# -gt 0 ]]; do
  case "${1}" in
    -m|--message)
      MESSAGE="${2}"; shift 2 ;;
    -f|--file)
      FILE_SPECS+=( "${2}" ); shift 2 ;;
    *)
      echo "Unknown option: ${1}" >&2
      exit 1 ;;
  esac
done

if [[ -z "${MESSAGE}" ]]; then
  echo "ERROR: -m/--message is required" >&2
  exit 1
fi
if [[ ${#FILE_SPECS[@]} -eq 0 ]]; then
  echo "ERROR: at least one -f/--file is required" >&2
  exit 1
fi

# Installation token (cached by get-token.sh). The script is run by bash, so
# just invoke it directly; BASH_EXE is only needed when spawning bash from
# outside bash (e.g. PowerShell).
TOKEN="$(bash "${DIR}/get-token.sh")"
API="${API_BASE}/repos/${REPO}"

# JSON/GraphQL-escape a string (backslashes first, then double quotes).
json_escape() {
  printf '%s' "${1}" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# 1) Current HEAD sha of the branch.
HEAD_JSON="$(curl -fsSL -H "Authorization: Bearer ${TOKEN}" -H "Accept: application/vnd.github+json" "${API}/git/refs/heads/${BRANCH}")"
HEAD_SHA="$(printf '%s' "${HEAD_JSON}" | tr -d '\n \t' | sed -n 's/.*"object":{"sha":"\([^"]*\)".*/\1/p')"
if [[ -z "${HEAD_SHA}" ]]; then
  echo "ERROR: branch ${BRANCH} not found (does it exist?)" >&2
  exit 1
fi

# 2) Base64 content for every changed file (exact bytes, no newline mangling).
declare -a ADDITIONS=()
for spec in "${FILE_SPECS[@]}"; do
  file_path="${spec%%=*}"
  raw="${spec#*=}"
  if [[ "${raw}" == @* ]]; then
    f="${raw#@}"
    if [[ ! -f "${f}" ]]; then
      echo "ERROR: file not found: ${f}" >&2
      exit 1
    fi
    B64="$(openssl base64 -A -in "${f}")"
  else
    B64="$(printf '%s' "${raw}" | openssl base64 -A)"
  fi
  EP="$(json_escape "${file_path}")"
  ADDITIONS+=( "{path:\"${EP}\",contents:\"${B64}\"}" )
done
ADD_LIST="$(IFS=,; echo "${ADDITIONS[*]}")"
EB="$(json_escape "${BRANCH}")"
EM="$(json_escape "${MESSAGE}")"

# 3) Create the single verified commit with createCommitOnBranch.
#    GitHub commits it (committer: GitHub <noreply@github.com>) and signs it.
QUERY="mutation { createCommitOnBranch(input:{branch:{repositoryNameWithOwner:\"${REPO}\",branchName:\"${EB}\"},message:{headline:\"${EM}\"},expectedHeadOid:\"${HEAD_SHA}\",fileChanges:{additions:[${ADD_LIST}]}}){commit{oid}}}"
BODY="{\"query\":\"$(json_escape "${QUERY}")\"}"

RESP="$(curl -fsSL -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${BODY}" \
  "${GRAPHQL}")"
COMMIT_SHA="$(printf '%s' "${RESP}" | tr -d '\n \t' | sed -n 's/.*"createCommitOnBranch":{"commit":{"oid":"\([^"]*\)".*/\1/p')"
if [[ -z "${COMMIT_SHA}" ]]; then
  echo "ERROR: commit creation failed: ${RESP}" >&2
  exit 1
fi

printf '%s' "${COMMIT_SHA}"