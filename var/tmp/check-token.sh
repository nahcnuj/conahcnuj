#!/usr/bin/env bash
cd /c/Users/nahcnuj/conahcnuj || exit 1
TOKEN=$(cat var/tmp/token.txt | tr -d '\r\n')
curl -s --globoff \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -o var/tmp/repo-check.json \
  "https://api.github.com/repos/nahcnuj/conahcnuj"
echo "exit=$? size=$(wc -c < var/tmp/repo-check.json)"
head -c 160 var/tmp/repo-check.json
echo