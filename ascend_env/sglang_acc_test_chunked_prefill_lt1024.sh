#!/usr/bin/env bash
set -euo pipefail

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-6699}"
MODEL_PATH="${MODEL_PATH:-/home/caofei/DeepSeek-V3.2-Exp-w8a8}"
MAX_TOKENS="${MAX_TOKENS:-2048}"

PROMPT='You are auditing a deterministic warehouse ledger. The ledger starts with 900 usable units. Accepted units increase inventory, shipped units decrease inventory, damaged removals decrease inventory, inbound transfers increase inventory, and outbound transfers decrease inventory. Verify the arithmetic, decide whether the checkpoints are consistent, and state the final usable balance.

Records:
Record 001: accepted 21 units, shipped 14 units, removed 2 damaged units, transfer inbound 9 units, checkpoint balance 914.
Record 002: accepted 25 units, shipped 19 units, removed 4 damaged units, transfer outbound 12 units, checkpoint balance 904.
Record 003: accepted 29 units, shipped 24 units, removed 1 damaged unit, transfer outbound 6 units, checkpoint balance 902.
Record 004: accepted 33 units, shipped 10 units, removed 3 damaged units, transfer inbound 13 units, checkpoint balance 935.
Record 005: accepted 37 units, shipped 15 units, removed 0 damaged units, transfer inbound 7 units, checkpoint balance 964.
Record 006: accepted 18 units, shipped 20 units, removed 2 damaged units, transfer outbound 14 units, checkpoint balance 946.
Record 007: accepted 22 units, shipped 25 units, removed 4 damaged units, transfer outbound 8 units, checkpoint balance 931.
Record 008: accepted 26 units, shipped 11 units, removed 1 damaged unit, transfer inbound 15 units, checkpoint balance 960.
Record 009: accepted 30 units, shipped 16 units, removed 3 damaged units, transfer inbound 9 units, checkpoint balance 980.
Record 010: accepted 34 units, shipped 21 units, removed 0 damaged units, transfer outbound 3 units, checkpoint balance 990.
Record 011: accepted 38 units, shipped 26 units, removed 2 damaged units, transfer outbound 10 units, checkpoint balance 990.
Record 012: accepted 19 units, shipped 12 units, removed 4 damaged units, transfer inbound 4 units, checkpoint balance 997.
Record 013: accepted 23 units, shipped 17 units, removed 1 damaged unit, transfer inbound 11 units, checkpoint balance 1013.
Record 014: accepted 27 units, shipped 22 units, removed 3 damaged units, transfer outbound 5 units, checkpoint balance 1010.
Record 015: accepted 31 units, shipped 27 units, removed 0 damaged units, transfer outbound 12 units, checkpoint balance 1002.
Record 016: accepted 35 units, shipped 13 units, removed 2 damaged units, transfer inbound 6 units, checkpoint balance 1028.
Record 017: accepted 39 units, shipped 18 units, removed 4 damaged units, transfer inbound 13 units, checkpoint balance 1058.
Record 018: accepted 20 units, shipped 23 units, removed 1 damaged unit, transfer outbound 7 units, checkpoint balance 1047.
Record 019: accepted 24 units, shipped 9 units, removed 3 damaged units, transfer outbound 14 units, checkpoint balance 1045.
Record 020: accepted 28 units, shipped 14 units, removed 0 damaged units, transfer inbound 8 units, checkpoint balance 1067.

Final instruction: Audit the records above. Give the consistency judgment, final balance, and a short reason.'

json_prompt=${PROMPT//\\/\\\\}
json_prompt=${json_prompt//\"/\\\"}
json_prompt=${json_prompt//$'\n'/\\n}

curl "http://${HOST}:${PORT}/v1/completions" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL_PATH}\",\"prompt\":\"${json_prompt}\",\"max_tokens\":${MAX_TOKENS},\"temperature\":0}"
