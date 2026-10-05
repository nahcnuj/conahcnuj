#!/usr/bin/env bash
# driver_commit_message test (offline).
#
# The driver labels its own commit, because the coding agent is not asked for a
# message: an agent handed both the change and a message sometimes answers with
# the message and no change (issue #146). A .commit-msg is used when one exists
# (repositories whose own agent instructions ask for one), a missing one must
# never cost the finished change, and every case yields one line.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"

ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT

export CONAHCNUJ_TEST_MODE=1
export CONAHCNUJ_IMPORT=1
# shellcheck source=bin/conahcnuj.sh
. "${REPO}/bin/conahcnuj.sh"

cd "${ROOT}" || exit 1

# 1. No .commit-msg: the item's title labels the commit.
out="$(driver_commit_message "issue駆動自律開発" 2>/dev/null)"
[[ "${out}" == "issue駆動自律開発" ]] || { echo "FAIL: expected the title, got '${out}'" >&2; exit 1; }
echo "driver_commit_message (no .commit-msg) -> title: passed"

# 2. A follow-up round is better described by its subject than by the issue it
#    belongs to.
out="$(driver_commit_message "issue駆動自律開発" "Fix the pull request's failing checks" 2>/dev/null)"
[[ "${out}" == "Fix the pull request's failing checks" ]] || { echo "FAIL: expected the subject, got '${out}'" >&2; exit 1; }
echo "driver_commit_message (subject) -> subject: passed"

# 3. A .commit-msg is honoured and consumed: the change, not the label, is what
#    reaches the branch.
printf 'Real message from the agent\n\nBody the driver must not use\n' > .commit-msg
out="$(driver_commit_message "issue駆動自律開発" 2>/dev/null)"
[[ "${out}" == "Real message from the agent" ]] || { echo "FAIL: expected the agent's message, got '${out}'" >&2; exit 1; }
[[ ! -e .commit-msg ]] || { echo "FAIL: .commit-msg must be consumed" >&2; exit 1; }
echo "driver_commit_message (.commit-msg) -> agent message: passed"

# 4. A blank .commit-msg falls back instead of committing with nothing.
printf '   \n' > .commit-msg
out="$(driver_commit_message "issue駆動自律開発" 2>/dev/null)"
[[ "${out}" == "issue駆動自律開発" ]] || { echo "FAIL: a blank message must fall back, got '${out}'" >&2; exit 1; }
[[ ! -e .commit-msg ]] || { echo "FAIL: a blank .commit-msg must still be consumed" >&2; exit 1; }
echo "driver_commit_message (blank .commit-msg) -> fallback: passed"

# 5. Neither a label nor a title to derive one from: still one usable line.
out="$(driver_commit_message "" "" 2>/dev/null)"
[[ -n "${out}" ]] || { echo "FAIL: no message at all" >&2; exit 1; }
[[ "$(printf '%s\n' "${out}" | wc -l)" == "1" ]] || { echo "FAIL: the message must be one line" >&2; exit 1; }
echo "driver_commit_message (nothing to derive from) -> fallback: passed"

echo "driver_commit_message passed"
