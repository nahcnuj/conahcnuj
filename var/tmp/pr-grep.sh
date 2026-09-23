#!/usr/bin/env bash
cd /c/Users/nahcnuj/conahcnuj || exit 1
grep -o '"state": "[a-z]*"\|"merged": [a-z]*\|"merged_at": "[^"]*"\|"review_decision": "[^"]*"' var/tmp/pr-check.json | head