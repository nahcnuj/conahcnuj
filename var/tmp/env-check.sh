#!/usr/bin/env bash
cd /c/Users/nahcnuj/conahcnuj || exit 1
echo "pwd=$(pwd)"
echo "--- files ---"
for p in bin/conahcnuj.sh lib/gh-api.sh lib/opencode.sh lib/rate-limit.sh tests/test.sh test.sh Dockerfile docker-run.sh; do
  if [ -e "$p" ]; then echo "OK $p"; else echo "MISSING $p"; fi
done
echo "--- docker ---"
command -v docker && docker images --format '{{.Repository}}:{{.Tag}}' | head -10 || echo "docker not available"
echo "--- git ---"
git log --oneline -5