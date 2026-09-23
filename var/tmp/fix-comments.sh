#!/usr/bin/env bash
cd /c/Users/nahcnuj/conahcnuj || exit 1
TOKEN=$(cat var/tmp/token.txt | tr -d '\r\n')

fix_thread() {
  local id="$1" f="$2"
  echo "=== review comment $id ==="
  curl -s -X PATCH \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/nahcnuj/conahcnuj/pulls/comments/$id" \
    --data-binary "@$f" -o "var/tmp/resp-$id.json"
  echo "response bytes: $(wc -c < "var/tmp/resp-$id.json")"
  grep -o '"body":"[^"]*"' "var/tmp/resp-$id.json" | head -c 300
  echo
}

fix_issue() {
  local id="$1" f="$2"
  echo "=== issue comment $id ==="
  curl -s -X PATCH \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/nahcnuj/conahcnuj/issues/comments/$id" \
    --data-binary "@$f" -o "var/tmp/resp-$id.json"
  echo "response bytes: $(wc -c < "var/tmp/resp-$id.json")"
  grep -o '"body":"[^"]*"' "var/tmp/resp-$id.json" | head -c 300
  echo
}

fix_thread 4078274248 var/tmp/fix1.json
fix_thread 4078274690 var/tmp/fix2.json
fix_issue  5787526961 var/tmp/fix3.json
fix_issue  5787553720 var/tmp/fix4.json