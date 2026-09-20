#!/usr/bin/env bash
# Create a verified commit on a branch through the GitHub GraphQL API using the
# GitHub App installation token. Commits created with createCommitOnBranch are
# committed by GitHub and signed with GitHub's verified signature, so they carry
# the green "Verified" badge and satisfy branch rules such as
# "Commits must have verified signatures".
#
# Usage (run inside the repo; owner/repo/branch are auto-detected from git).
# Collection modes mirror `git commit` flags; the difference from plain git
# is only where the commit is created: file contents are sent to the GitHub
# API, which creates the commit server-side and signs it. That server-side
# signature is the whole point: only GitHub-signed commits satisfy
# "Commits must have verified signatures".
#   bash gh-app/api-commit.sh -m "<message>"            # staged (git commit)
#   bash gh-app/api-commit.sh -m "<message>" -a         # tracked worktree (git commit -a)
#   bash gh-app/api-commit.sh -m "<message>" --all      # everything incl. untracked (git add -A + commit)
#   bash gh-app/api-commit.sh -m "<message>" --file path=@file [--delete path]
#   bash gh-app/api-commit.sh <owner>/<repo> <branch> -m "<message>" --all
#   bash gh-app/api-commit.sh <branch> -m "<message>" --all   # repo auto-detected
#   bash gh-app/api-commit.sh <owner>/<repo> -m "<message>" --all  # branch auto-detected
#
# Options:
#   -a                Commit tracked worktree changes (modified/deleted tracked
#                     files, staged or not; untracked files excluded).
#   --all             Commit every worktree change (added/modified/untracked files
#                     and deletions) in a single verified commit.
#   --file p=c|p=@f   Add/update file p with inline content c or @local file f.
#   --delete path     Delete path from the branch.
#   --create-branch   Create <branch> from the default branch if it does not
#                     exist yet (no unsigned commits involved).
#   --dry-run         Print what would be committed without calling the API
#                     (no token/network needed; usable for offline tests).
#
# The author identity is the App (conahcnuj[bot]) and the committer is GitHub.com.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${DIR}/app.env"
if [[ ! -f "${ENV_FILE}" && -f "${DIR}/app.env.example" ]]; then
  ENV_FILE="${DIR}/app.env.example"
fi

set -a
# shellcheck source=gh-app/app.env.example
. "${ENV_FILE}"
set +a

API_BASE="${GH_APP_API_BASE:-https://api.github.com}"
GRAPHQL="${API_BASE}/graphql"

# Usage: <owner>/<repo> or empty.
auto_repo() {
  local url
  url="$(git remote get-url origin 2>/dev/null || true)"
  if [[ -z "${url}" ]]; then
    echo "ERROR: cannot auto-detect <owner>/<repo>. Pass it as the first argument (git remote origin is not set)." >&2
    exit 1
  fi
  printf '%s' "${url}" | sed -E 's#.*github\.com[:/]##; s#\.git$##'
}

MESSAGE=""
declare -a FILE_SPECS=()
declare -a DELETE_PATHS=()
ALL=false
TRACKED=false
CREATE_BRANCH=false
DRY_RUN=false
REPO=""
BRANCH=""

# First two positional args may be <owner>/<repo> <branch> when present.
if [[ $# -ge 2 && "${1}" != -* && "${2}" != -* ]]; then
  REPO="${1}"
  BRANCH="${2}"
  shift 2
# A single positional arg is <owner>/<repo> if it contains "/", else <branch>;
# the other side is auto-detected.
elif [[ $# -ge 1 && "${1}" != -* ]]; then
  if [[ "${1}" == */* ]]; then
    REPO="${1}"
  else
    BRANCH="${1}"
  fi
  shift
fi

while [[ $# -gt 0 ]]; do
  case "${1}" in
    -m|--message)
      MESSAGE="${2}"; shift 2 ;;
    -f|--file)
      FILE_SPECS+=( "${2}" ); shift 2 ;;
    -d|--delete)
      DELETE_PATHS+=( "${2}" ); shift 2 ;;
    -a)
      TRACKED=true; shift ;;
    --all)
      ALL=true; shift ;;
    --create-branch)
      CREATE_BRANCH=true; shift ;;
    --dry-run)
      DRY_RUN=true; shift ;;
    *)
      echo "Unknown option: ${1}" >&2
      exit 1 ;;
  esac
done

if [[ -z "${REPO}" ]]; then
  REPO="$(auto_repo)"
fi
if [[ -z "${BRANCH}" ]]; then
  BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [[ -z "${BRANCH}" ]]; then
    echo "ERROR: cannot auto-detect <branch>. Pass it as the second argument (not inside a git work tree)." >&2
    exit 1
  fi
fi

if [[ -z "${MESSAGE}" ]]; then
  echo "ERROR: -m/--message is required" >&2
  echo "Usage: bash gh-app/api-commit.sh [-m <message>] [(-a | --all) | (--file p=c|p=@f ...)] [options]" >&2
  exit 1
fi
if [[ "${ALL}" == true && "${TRACKED}" == true ]]; then
  echo "ERROR: --all and -a are mutually exclusive" >&2
  exit 1
fi
if [[ ("${ALL}" == true || "${TRACKED}" == true) && ${#FILE_SPECS[@]} -gt 0 ]]; then
  echo "ERROR: --all/-a and --file are mutually exclusive" >&2
  exit 1
fi
# No collection flag and no explicit files: commit staged changes like
# plain `git commit`.
STAGED=false
if [[ "${ALL}" != true && "${TRACKED}" != true && ${#FILE_SPECS[@]} -eq 0 && ${#DELETE_PATHS[@]} -eq 0 ]]; then
  STAGED=true
fi

# JSON/GraphQL-escape a string (backslashes first, then double quotes).
json_escape() {
  printf '%s' "${1}" | sed 's/\\/\\\\/g; s/"/\\"/g'
}
# 1) Collect added/modified file contents (exact bytes, no newline mangling) and
#    deletion paths. No network/token needed up to and including --dry-run.
declare -a ADDITIONS=()

collect_worktree_changes() {
  local entry status path u pending_rename_new
  declare -a ADD_PATHS_COLLECT=()
  pushd "$(git rev-parse --show-toplevel)" >/dev/null || exit 1
  # Tracked changes: A/M/R/D. With -z, a rename is two records: "R  <new>",
  # then just the old path (verified: `R  b.txt\0a.txt\0`).
  # Untracked (??) are collected via --others below.
  pending_rename_new=""
  while IFS= read -r -d '' entry; do
    status="${entry:0:2}"
    path="${entry:3}"
    if [[ -n "${pending_rename_new}" ]]; then
      DELETE_PATHS+=( "${entry}" )
      pending_rename_new=""
      continue
    fi
    case "${status}" in
      '??') ;;
      R*) ADD_PATHS_COLLECT+=( "${path}" ); pending_rename_new="1" ;;
      *D*) DELETE_PATHS+=( "${path}" ) ;;
      *) ADD_PATHS_COLLECT+=( "${path}" ) ;;
    esac
  done < <(git status --porcelain -z)
  # Untracked files (real files, not the containing directory).
  # Skipped for -a, mirroring `git commit -a` (untracked files excluded).
  if [[ "${INCLUDE_UNTRACKED}" == true ]]; then
    while IFS= read -r -d '' u; do
      ADD_PATHS_COLLECT+=( "${u}" )
    done < <(git ls-files --others --exclude-standard -z)
  fi
  popd >/dev/null || exit 1
  mapfile -t ADD_FILES < <(printf '%s\n' "${ADD_PATHS_COLLECT[@]}" | sort -u | sed '/^$/d')
}

declare -a ADD_FILES=()
FROM_INDEX=false

# Staged changes (like plain `git commit`): content comes from the index via
# `git show :path`. Format (verified): `D\0path`, `A\0path`, `R100\0old\0new`.
collect_staged_changes() {
  local st path old new
  declare -a ADD_PATHS_COLLECT=()
  pushd "$(git rev-parse --show-toplevel)" >/dev/null || exit 1
  while IFS= read -r -d '' st; do
    case "${st}" in
      R*|C*)
        IFS= read -r -d '' old || exit 1
        IFS= read -r -d '' new || exit 1
        ADD_PATHS_COLLECT+=( "${new}" )
        if [[ "${st}" == R* ]]; then
          DELETE_PATHS+=( "${old}" )
        fi
        ;;
      D)
        IFS= read -r -d '' path || exit 1
        DELETE_PATHS+=( "${path}" )
        ;;
      A|M|T)
        IFS= read -r -d '' path || exit 1
        ADD_PATHS_COLLECT+=( "${path}" )
        ;;
      *)
        echo "ERROR: unexpected diff status: ${st}" >&2
        exit 1 ;;
    esac
  done < <(git diff --cached --name-status -z)
  popd >/dev/null || exit 1
  mapfile -t ADD_FILES < <(printf '%s\n' "${ADD_PATHS_COLLECT[@]}" | sort -u | sed '/^$/d')
}

INCLUDE_UNTRACKED=true
if [[ "${ALL}" == true ]]; then
  collect_worktree_changes
elif [[ "${TRACKED}" == true ]]; then
  INCLUDE_UNTRACKED=false
  collect_worktree_changes
elif [[ "${STAGED}" == true ]]; then
  FROM_INDEX=true
  collect_staged_changes
fi

# Explicit --file specs first (kept order), then auto-collected files.
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

for f in "${ADD_FILES[@]}"; do
  if [[ "${FROM_INDEX}" == true ]]; then
    # Staged content (may differ from the worktree file).
    B64="$(git show ":${f}" | openssl base64 -A)"
  else
    if [[ ! -f "${f}" ]]; then
      echo "ERROR: file not found: ${f}" >&2
      exit 1
    fi
    B64="$(openssl base64 -A -in "${f}")"
  fi
  EP="$(json_escape "${f}")"
  ADDITIONS+=( "{path:\"${EP}\",contents:\"${B64}\"}" )
done

if [[ ${#ADDITIONS[@]} -eq 0 && ${#DELETE_PATHS[@]} -eq 0 ]]; then
  echo "ERROR: nothing to commit (nothing staged; stage with git add or use --all)" >&2
  exit 1
fi

if [[ "${DRY_RUN}" == true ]]; then
  echo "Owner/Repo: ${REPO}"
  echo "Branch:     ${BRANCH}"
  echo "Message:    ${MESSAGE}"
  echo "Additions:  ${#ADDITIONS[@]} file(s)"
  if [[ ${#ADD_FILES[@]} -gt 0 ]]; then
    printf '  %s\n' "${ADD_FILES[@]}"
  fi
  for spec in "${FILE_SPECS[@]}"; do
    printf '  %s\n' "${spec%%=*}"
  done
  echo "Deletions:  ${#DELETE_PATHS[@]} file(s)"
  if [[ ${#DELETE_PATHS[@]} -gt 0 ]]; then
    printf '  %s\n' "${DELETE_PATHS[@]}"
  fi
  exit 0
fi

# Installation token (cached by get-token.sh). The script is run by bash, so
# just invoke it directly; BASH_EXE is only needed when spawning bash from
# outside bash (e.g. PowerShell).
TOKEN="$(bash "${DIR}/get-token.sh")"
API="${API_BASE}/repos/${REPO}"

# 2) Current HEAD sha of the branch (|| true: a missing branch must fall
#    through to the --create-branch handling instead of tripping set -e).
HEAD_JSON="$(curl -fsSL -H "Authorization: Bearer ${TOKEN}" -H "Accept: application/vnd.github+json" "${API}/git/refs/heads/${BRANCH}" || true)"
HEAD_SHA="$(printf '%s' "${HEAD_JSON}" | tr -d '\n \t' | sed -n 's/.*"object":{"sha":"\([^"]*\)".*/\1/p')"
if [[ -z "${HEAD_SHA}" ]]; then
  if [[ "${CREATE_BRANCH}" != true ]]; then
    echo "ERROR: branch ${BRANCH} not found (does it exist? use --create-branch to create it from the default branch)" >&2
    exit 1
  fi
  # 2b) Create the branch ref from the default branch head (no commits pushed).
  DEFAULT_BRANCH="$(curl -fsSL -H "Authorization: Bearer ${TOKEN}" -H "Accept: application/vnd.github+json" "${API}" | tr -d '\n \t' | sed -n 's/.*"default_branch":"\([^"]*\)".*/\1/p')"
  if [[ -z "${DEFAULT_BRANCH}" ]]; then
    echo "ERROR: cannot determine default branch of ${REPO}" >&2
    exit 1
  fi
  BASE_JSON="$(curl -fsSL -H "Authorization: Bearer ${TOKEN}" -H "Accept: application/vnd.github+json" "${API}/branches/${DEFAULT_BRANCH}")"
  BASE_SHA="$(printf '%s' "${BASE_JSON}" | tr -d '\n \t' | sed -n 's/.*"commit":{"sha":"\([^"]*\)".*/\1/p')"
  if [[ -z "${BASE_SHA}" ]]; then
    echo "ERROR: cannot determine head of ${DEFAULT_BRANCH}" >&2
    exit 1
  fi
  BODY="{\"ref\":\"refs/heads/${BRANCH}\",\"sha\":\"${BASE_SHA}\"}"
  curl -fsSL -X POST -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" -H "Accept: application/vnd.github+json" -d "${BODY}" "${API}/git/refs" >/dev/null
  echo "Created branch ${BRANCH} from ${DEFAULT_BRANCH}" >&2
  HEAD_SHA="${BASE_SHA}"
fi

ADD_LIST="$(IFS=,; echo "${ADDITIONS[*]}")"
declare -a DEL_LIST_ARR=()
for dp in "${DELETE_PATHS[@]}"; do
  DEL_LIST_ARR+=( "\"$(json_escape "${dp}")\"" )
done
DEL_LIST="$(IFS=,; echo "${DEL_LIST_ARR[*]}")"
EB="$(json_escape "${BRANCH}")"
EM="$(json_escape "${MESSAGE}")"

# 3) Create the single verified commit with createCommitOnBranch.
#    GitHub commits it (committer: GitHub <noreply@github.com>) and signs it.
QUERY="mutation { createCommitOnBranch(input:{branch:{repositoryNameWithOwner:\"${REPO}\",branchName:\"${EB}\"},message:{headline:\"${EM}\"},expectedHeadOid:\"${HEAD_SHA}\",fileChanges:{additions:[${ADD_LIST}],deletions:[${DEL_LIST}]}}){commit{oid}}}"
# Pass the body via file: inline -d breaks Windows' 32KB command-line limit
# when committing large files.
BODY_FILE="$(mktemp)"
trap 'rm -f "${BODY_FILE:-}"' EXIT
printf '%s' "{\"query\":\"$(json_escape "${QUERY}")\"}" > "${BODY_FILE}"

RESP="$(curl -fsSL -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  --data-binary "@${BODY_FILE}" \
  "${GRAPHQL}")"
COMMIT_SHA="$(printf '%s' "${RESP}" | tr -d '\n \t' | sed -n 's/.*"createCommitOnBranch":{"commit":{"oid":"\([^"]*\)".*/\1/p')"
if [[ -z "${COMMIT_SHA}" ]]; then
  echo "ERROR: commit creation failed: ${RESP}" >&2
  exit 1
fi

printf '%s' "${COMMIT_SHA}"