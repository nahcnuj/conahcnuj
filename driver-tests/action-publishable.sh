#!/usr/bin/env bash
# action.yml must exist at the repository root and be a valid GitHub Actions
# metadata file suitable for GitHub Marketplace publication: a single metadata
# file at the root, a composite `runs.using`, a unique-ish name, description,
# author, and valid branding (icon + color). See:
# https://docs.github.com/en/actions/how-tos/create-and-publish-actions/publish-in-github-marketplace
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
ACTION="${REPO}/action.yml"

[[ -f "${ACTION}" ]] || { echo "FAIL: missing root action.yml (required for Marketplace)"; exit 1; }

python3 - "${ACTION}" <<'PY'
import re, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    text = f.read()

# Required top-level keys (present as `key:` at column 0).
for key in ("name", "description", "author", "branding", "runs"):
    assert re.search(r"(?m)^" + re.escape(key) + r"\s*:", text), \
        "action.yml missing required key: " + key

# runs.using must be a valid action runtime.
m = re.search(r"(?ms)^runs:\s*\n(?:[ \t]+.*\n)*?[ \t]+using:\s*(\S+)\s*$", text)
assert m, "action.yml missing runs.using"
assert m.group(1) in {"composite", "docker", "node12", "node16", "node20"}, \
    "runs.using must be a valid action runtime"

# branding color must be one of GitHub's allowed values.
colors = {"white", "yellow", "blue", "green", "orange", "red", "purple", "gray-dark"}
cm = re.search(r"(?ms)^branding:\s*\n(?:[ \t]+.*\n)*?[ \t]+color:\s*(\S+)\s*$", text)
assert cm, "branding must set color"
color_val = cm.group(1).strip().strip("'\"")
assert color_val in colors, "invalid branding color: " + color_val

# branding icon must be present.
assert re.search(r"(?ms)^branding:\s*\n(?:[ \t]+.*\n)*?[ \t]+icon:\s*\S+", text), \
    "branding must set icon"

# name must be a non-empty scalar.
nm = re.search(r"(?m)^name:\s*(.+?)\s*$", text)
assert nm and nm.group(1).strip(), "name must be non-empty"
print("action.yml Marketplace metadata OK")
PY

# The reusable workflows that carry the real automation must exist and be reusable.
for wf in issue-driver.yml owner-approved-auto-merge.yml; do
  [[ -f "${REPO}/.github/workflows/${wf}" ]] || { echo "FAIL: missing ${wf}"; exit 1; }
  grep -q "workflow_call" "${REPO}/.github/workflows/${wf}" \
    || { echo "FAIL: ${wf} is not a reusable workflow"; exit 1; }
done

echo "action publishable checks passed"
