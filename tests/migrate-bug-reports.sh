#!/usr/bin/env bash
# migrate-bug-reports.sh offline test: old auto-filed bug-report issues are
# re-posted to the Discussions Bug report category (issue #126), with the
# original issue getting a pointer comment.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"

ROOT="$(mktemp -d)"
trap 'rm -rf "${ROOT}"' EXIT

export CONAHCNUJ_TEST_MODE=1
export GH_API_TEST_MODE=1
export OPENCODE_TEST_MODE=1

TAPE="${ROOT}/tape.txt"
cat > "${TAPE}" <<'TAPE'
{"items":[{"number":31,"title":"conahcnuj: failed to resolve #20 (exit 1)","body":"## Error log\n\nboom one","html_url":"https://github.com/nahcnuj/conahcnuj/issues/31"},{"number":32,"title":"conahcnuj: driver terminated abnormally (exit 1)","body":"## Error log\n\nboom \"two\"\nwith } brace","html_url":"https://github.com/nahcnuj/conahcnuj/issues/32"}]}
{"data":{"repository":{"discussionCategories":{"nodes":[{"id":"DIC_kwDO456","name":"Bug report"}]}}}}
{"data":{"repository":{"discussions":{"nodes":[]}}}}
{"data":{"repository":{"id":"R_kgDO123"}}}
{"data":{"createDiscussion":{"discussion":{"number":26,"url":"https://github.com/nahcnuj/conahcnuj/discussions/26"}}}}
{"id":555}
{"data":{"repository":{"discussionCategories":{"nodes":[{"id":"DIC_kwDO456","name":"Bug report"}]}}}}
{"data":{"repository":{"discussions":{"nodes":[{"id":"D_9","number":26,"title":"conahcnuj: driver terminated abnormally (exit 1)","url":"https://github.com/nahcnuj/conahcnuj/discussions/26"}]}}}}
{"data":{"addDiscussionComment":{"comment":{"id":"DIC_9"}}}}
{"id":556}
TAPE

OUT="${ROOT}/out.log"
bash "${REPO}/bin/migrate-bug-reports.sh" "nahcnuj" "conahcnuj" < "${TAPE}" > "${OUT}" 2>&1

cat "${OUT}"

grep -q "Migrating bug-report issue #31" "${OUT}" || { echo "FAIL: issue #31 not migrated"; exit 1; }
grep -q "Re-posted as discussion #26" "${OUT}" || { echo "FAIL: no discussion created"; exit 1; }
grep -q "Re-posted as comment #26" "${OUT}" || { echo "FAIL: same-title report was not grouped into the existing thread"; exit 1; }

echo "migrate-bug-reports passed"
