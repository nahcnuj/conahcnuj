#!/usr/bin/env bash
cd /c/Users/nahcnuj/conahcnuj
bash gh-app/api-commit.sh nahcnuj/conahcnuj main \
  -m "fix: restore README markdown formatting and add mock tests for Python date fallback" \
  --file "README.md=@README.md" \
  --file "gh-app/mock-test.sh=@gh-app/mock-test.sh"