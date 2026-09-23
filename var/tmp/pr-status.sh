#!/usr/bin/env bash
cd /c/Users/nahcnuj/conahcnuj || exit 1
TOKEN=$(cat var/tmp/token.txt | tr -d '\r\n')
curl -s --globoff \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -o var/tmp/pr-check.json \
  "https://api.github.com/repos/nahcnuj/conahcnuj/pulls/18"
echo "exit=$? size=$(wc -c < var/tmp/pr-check.json)"
grep -o '"state":"[a-z]*"\|"merged":[a-z]*\|"merged_at":"[^"]*"\|"review_decision":"[^"]*"' var/tmp/pr-check.json | head