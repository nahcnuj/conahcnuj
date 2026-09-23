#!/usr/bin/env bash
cd /c/Users/nahcnuj/conahcnuj || exit 1
for id in 4078274248 4078274690 5787526961 5787553720; do
  echo "=== $id ==="
  python -c "import json,sys; d=json.load(open('var/tmp/resp-$id.json',encoding='utf-8')); print(d.get('body') or d.get('message') or d)"
done