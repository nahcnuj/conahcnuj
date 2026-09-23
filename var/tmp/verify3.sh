#!/usr/bin/env bash
cd /c/Users/nahcnuj/conahcnuj || exit 1
for id in 4078274248 4078274690 5787526961 5787553720; do
  echo "=== $id ==="
  grep '"body"' "var/tmp/resp-$id.json" | sed 's/  "body": "//; s/",$//'
  echo
done