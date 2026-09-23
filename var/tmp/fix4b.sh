#!/usr/bin/env bash
cd /c/Users/nahcnuj/conahcnuj || exit 1
TOKEN=$(cat var/tmp/token.txt | tr -d '\r\n')
id=5787553720
curl -s -X PATCH \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/nahcnuj/conahcnuj/issues/comments/$id" \
  --data-binary "@var/tmp/fix4b.json" -o "var/tmp/resp-$id.json"
echo "bytes=$(wc -c < "var/tmp/resp-$id.json")"
grep '"body"' "var/tmp/resp-$id.json" | sed 's/  "body": "//; s/",$//'