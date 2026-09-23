#!/usr/bin/env bash
cd /c/Users/nahcnuj/conahcnuj || exit 1
TOKEN=$(cat var/tmp/token.txt | tr -d '\r\n')
curl -s --globoff \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -o var/tmp/issues.json \
  "https://api.github.com/repos/nahcnuj/conahcnuj/issues?state=open&per_page=30"
echo "exit=$? size=$(wc -c < var/tmp/issues.json)"
grep -o '"number": [0-9]*\|"title": "[^"]*"\|"state": "[a-z]*"\|"html_url": "[^"]*"' var/tmp/issues.json | head -40