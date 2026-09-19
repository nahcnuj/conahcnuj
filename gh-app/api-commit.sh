#!/usr/bin/env bash
# Create a commit on a branch through the GitHub API using the GitHub App
# installation token. Commits created this way are signed by GitHub.com, so
# they carry the green "Verified" badge and satisfy branch rules such as
# "Commits must have verified signatures".
#
# Usage:
#   bash gh-app/api-commit.sh <owner>/<repo> <branch> \
#     -m "<message>" [--file <path>=<content-or-@path>] ...
#
# A file's content may be given inline (path=content) or as @file (path=@file).
# The author/committer identity is the App (conahcnuj[bot]) and Git records it
# as a "created on GitHub.com" verified commit.

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

# Installation token (cached by get-token.sh).
TOKEN="$(bash "${BASH_EXE}" "${DIR}/get-token.sh")"
AUTH_HEADER=(-H "Authorization: Bearer ${TOKEN}" -H "Accept: application/vnd.github+json")
API="${API_BASE}/repos/${REPO}"

b64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

# 1) Current HEAD sha + tree sha of the branch.
HEAD_JSON="$(curl -fsSL "${AUTH_HEADER[@]}" "${API}/git/refs/heads/${BRANCH}")"
HEAD_SHA="$(printf '%s' "${HEAD_JSON}" | sed -n 's/.*"object"[[:space:]]*:[[:space:]]*{[[:space:]]*"type"[[:space:]]*:[[:space:]]*"commit"[[:space:]]*,[[:space:]]*"sha"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
if [[ -z "${HEAD_SHA}" ]]; then
  echo "ERROR: branch ${BRANCH} not found (does it exist?)" >&2
  exit 1
fi
COMMIT_JSON="$(curl -fsSL "${AUTH_HEADER[@]}" "${API}/git/commits/${HEAD_SHA}")"
BASE_TREE_SHA="$(printf '%s' "${COMMIT_JSON}" | sed -n 's/.*"tree"[[:space:]]*:[[:space:]]*{[[:space:]]*"sha"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"

# 2) Create/read blobs for every changed file.
declare -a TREE_ENTRIES=()
for spec in "${FILE_SPECS[@]}"; do
  file_path="${spec%%=*}"
  content="${spec#*=}"
  if [[ "${content}" == @* && -f "${content#@}" ]]; then
    content="$(<"${content#@}")"
  elif [[ "${content}" == @* ]]; then
    echo "ERROR: file not found: ${content#@}" >&2
    exit 1
  fi
  B64="$(printf '%s' "${content}" | b64url)"
  BLOB_JSON="$(curl -fsSL -X POST "${AUTH_HEADER[@]}" \
    -H "Content-Type: application/json" \
    -d "{\"content\":\"${B64}\",\"encoding\":\"base64\"}" \
    "${API}/git/blobs")"
  BLOB_SHA="$(printf '%s' "${BLOB_JSON}" | sed -n 's/.*"sha"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  TREE_ENTRIES+=( "{\"path\":\"${file_path}\",\"mode\":\"100644\",\"type\":\"blob\",\"sha\":\"${BLOB_SHA}\"}" )
done

# 3) Build a new tree on top of the base tree.
TREE_LIST="$(IFS=,; echo "${TREE_ENTRIES[*]}")"
TREE_JSON="$(curl -fsSL -X POST "${AUTH_HEADER[@]}" \
  -H "Content-Type: application/json" \
  -d "{\"base_tree\":\"${BASE_TREE_SHA}\",\"tree\":[${TREE_LIST}]}" \
  "${API}/git/trees")"
NEW_TREE_SHA="$(printf '%s' "${TREE_JSON}" | sed -n 's/.*"sha"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"

# 4) Create the commit. GitHub signs it → Verified (satisfies branch rules
#    like "Commits must have verified signatures").
BOT_NAME="${APP_SLUG}[bot]"
BOT_EMAIL="${APP_ID}+${APP_SLUG}[bot]@users.noreply.github.com"
MSG_ESCAPED="${MESSAGE//\\/\\\\}"   # backslashes
MSG_ESCAPED="${MSG_ESCAPED//\"/\\\"}" # double quotes
COMMIT_JSON="$(curl -fsSL -X POST "${AUTH_HEADER[@]}" \
  -H "Content-Type: application/json" \
  -d "{\"message\":\"${MSG_ESCAPED}\",\"tree\":\"${NEW_TREE_SHA}\",\"parents\":[\"${HEAD_SHA}\"],\"author\":{\"name\":\"${BOT_NAME}\",\"email\":\"${BOT_EMAIL}\"},\"committer\":{\"name\":\"${BOT_NAME}\",\"email\":\"${BOT_EMAIL}\"}}" \
  "${API}/git/commits")"
COMMIT_SHA="$(printf '%s' "${COMMIT_JSON}" | sed -n 's/.*"sha"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"

# 5) Move the branch ref to the new commit.
curl -fsSL -X PATCH "${AUTH_HEADER[@]}" \
  -H "Content-Type: application/json" \
  -d "{\"sha\":\"${COMMIT_SHA}\",\"force\":false}" \
  "${API}/git/refs/heads/${BRANCH}" >/dev/null

printf '%s' "${COMMIT_SHA}"
