#!/usr/bin/env bash
cd /c/Users/nahcnuj/conahcnuj || exit 1
TOKEN=$(cat var/tmp/token.txt | tr -d '\r\n')
curl -s --globoff \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -o var/tmp/issue14.json \
  "https://api.github.com/repos/nahcnuj/conahcnuj/issues/14"
echo "exit=$? size=$(wc -c < var/tmp/issue14.json)"
grep '"title"\|"state"\|"created_at"\|"body"' var/tmp/issue14.json | head -20