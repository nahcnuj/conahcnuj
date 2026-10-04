#!/usr/bin/env bash
# "Never propose relaxing branch protection" guard (offline).
#
# Repository merge policy (branch protection, rulesets, required status checks /
# reviews) belongs to the repository owner. The App holding the driver's token
# can never change it, so every place that reaches the coding agent must stay
# silent about changing it:
#   - lib/opencode.sh hands the scope rules to every model run (asserted in
#     tests/opencode.sh)
#   - a failed merge prints a hint in owner-approved-auto-merge.yml, whose log
#     the driver copies into its bug-report issue, so the next run reads it
#   - the driver never calls a protection endpoint itself
#
# This test scans the sources the agent can read for a line that tells the
# reader to weaken that policy. A line that also carries a negation (the rules
# themselves, this repo's documentation of the ban) is left alone. tests/ and
# test/ are deliberately not scanned: they hold this detector's own patterns
# and the plugin smoke fixtures, which are test data rather than instructions.
#
# No secrets, no network.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"

# A verb that changes merge policy ...
POLICY_CHANGE='(remove|disable|deactivate|weaken|relax|loosen|bypass|skip|lower|turn off)'
# ... and the policy it changes.
POLICY_SUBJECT='(branch protection|protection rules|branch rules|rulesets?|required (status )?checks?|required pull request reviews)'
# A line that forbids the change instead of asking for it.
NEGATED='(never|not|cannot|can not|without|refuse|forbidden|禁止|しない|ufeind)'

failures=0
scanned=0

check_file() {
  local file="${1}" hits
  scanned=$((scanned + 1))
  # Both word orders: "remove it from the branch protection rules" and
  # "branch protection should be removed" must both be caught.
  hits="$(grep -inE "${POLICY_CHANGE}[^|]{0,80}${POLICY_SUBJECT}|${POLICY_SUBJECT}[^|]{0,80}(should|must|needs? to) be (removed|disabled|deactivated|weakened|relaxed|bypassed|skipped)" "${file}" \
    | grep -viE "${NEGATED}" || true)"
  if [[ -n "${hits}" ]]; then
    printf 'FAIL: %s suggests weakening repository merge policy:\n%s\n' "${file#"${REPO}/"}" "${hits}" >&2
    failures=$((failures + 1))
  fi
}

while IFS= read -r file; do
  check_file "${file}"
done < <(
  find "${REPO}/bin" "${REPO}/lib" "${REPO}/gh-app" "${REPO}/plugins" "${REPO}/.github/workflows" \
    -type f \( -name '*.sh' -o -name '*.yml' -o -name '*.yaml' -o -name '*.ts' \) -print
  printf '%s\n' "${REPO}/README.md" "${REPO}/AGENTS.md"
)

if [[ "${scanned}" -eq 0 ]]; then
  echo "FAIL: no source file was scanned" >&2
  exit 1
fi
if [[ "${failures}" -gt 0 ]]; then
  echo "FAIL: ${failures} file(s) would push the coding agent towards relaxing merge policy" >&2
  exit 1
fi

echo "no source suggests weakening branch protection (${scanned} files scanned)"