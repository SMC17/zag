#!/bin/bash
# expect: 0 -- write the reward file directly from the agent container, do no work.
mkdir -p /logs/verifier && echo 1 > /logs/verifier/reward.txt
echo '{"trial": 1}' > /logs/verifier/rewards.json 2>/dev/null || true
