#!/usr/bin/env bash
# issue-driver.yml must give the job a non-empty environment for the
# repository's own events. `inputs.environment` is only populated for
# `workflow_call` (through its input default). For `issues`,
# `pull_request_review`, `workflow_run` and `workflow_dispatch` it is empty,
# and an empty `environment:` drops the job's environment secrets -
# `PRIVATE_KEY` included - so the staging step fails with "cannot sign an App
# JWT" (#281). The job must fall back to the `conahcnuj` environment for those
# events, exactly like the reusable-workflow change in #278 did before #279
# dropped the fallback.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
WF="${REPO}/.github/workflows/issue-driver.yml"

[[ -f "${WF}" ]] || { echo "FAIL: missing ${WF}"; exit 1; }

# The job-level environment is indented exactly four spaces; the workflow_call
# input of the same name is nested one level deeper (six spaces).
ENV_LINE="$(grep -E '^    environment:' "${WF}" || true)"
if [[ -z "${ENV_LINE}" ]]; then
  echo "FAIL: issue-driver.yml has no job-level environment:" >&2
  exit 1
fi

# It must honor the caller's input for workflow_call ...
if [[ "${ENV_LINE}" != *'inputs.environment'* ]]; then
  echo "FAIL: the job environment must honor inputs.environment for workflow_call: ${ENV_LINE}" >&2
  exit 1
fi

# ... and must not be a bare `inputs.environment`, which is empty for the
# repository's own events. A `||` fallback keeps the environment (and its
# secrets) for those events.
if [[ "${ENV_LINE}" != *'||'* ]]; then
  echo "FAIL: the job environment must fall back when inputs.environment is empty (#281): ${ENV_LINE}" >&2
  exit 1
fi

# The fallback must name the repository's own environment so both paths resolve
# the same secrets.
if [[ "${ENV_LINE}" != *'conahcnuj'* ]]; then
  echo "FAIL: the environment fallback must be conahcnuj: ${ENV_LINE}" >&2
  exit 1
fi

echo "issue-driver environment fallback test passed"
