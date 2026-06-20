#!/usr/bin/env bash
set -euo pipefail

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-6699}"
MODEL_PATH="${MODEL_PATH:-/home/caofei/DeepSeek-V3.2-Exp-w8a8}"
MAX_TOKENS="${MAX_TOKENS:-2048}"

PROMPT='You are auditing a deterministic warehouse ledger. The ledger starts with 900 usable units. For every record, accepted units increase inventory, shipped units decrease inventory, damaged removals decrease inventory, inbound transfers increase inventory, and outbound transfers decrease inventory. Verify the arithmetic, identify whether the ledger is internally consistent, state the final usable balance, and cite several checkpoints. Keep the answer direct.

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
Record 021: accepted 32 units, shipped 19 units, removed 2 damaged units, transfer inbound 15 units, checkpoint balance 1093.
Record 022: accepted 36 units, shipped 24 units, removed 4 damaged units, transfer outbound 9 units, checkpoint balance 1092.
Record 023: accepted 17 units, shipped 10 units, removed 1 damaged unit, transfer outbound 3 units, checkpoint balance 1095.
Record 024: accepted 21 units, shipped 15 units, removed 3 damaged units, transfer inbound 10 units, checkpoint balance 1108.
Record 025: accepted 25 units, shipped 20 units, removed 0 damaged units, transfer inbound 4 units, checkpoint balance 1117.
Record 026: accepted 29 units, shipped 25 units, removed 2 damaged units, transfer outbound 11 units, checkpoint balance 1108.
Record 027: accepted 33 units, shipped 11 units, removed 4 damaged units, transfer outbound 5 units, checkpoint balance 1121.
Record 028: accepted 37 units, shipped 16 units, removed 1 damaged unit, transfer inbound 12 units, checkpoint balance 1153.
Record 029: accepted 18 units, shipped 21 units, removed 3 damaged units, transfer inbound 6 units, checkpoint balance 1153.
Record 030: accepted 22 units, shipped 26 units, removed 0 damaged units, transfer outbound 13 units, checkpoint balance 1136.
Record 031: accepted 26 units, shipped 12 units, removed 2 damaged units, transfer outbound 7 units, checkpoint balance 1141.
Record 032: accepted 30 units, shipped 17 units, removed 4 damaged units, transfer inbound 14 units, checkpoint balance 1164.
Record 033: accepted 34 units, shipped 22 units, removed 1 damaged unit, transfer inbound 8 units, checkpoint balance 1183.
Record 034: accepted 38 units, shipped 27 units, removed 3 damaged units, transfer outbound 15 units, checkpoint balance 1176.
Record 035: accepted 19 units, shipped 13 units, removed 0 damaged units, transfer outbound 9 units, checkpoint balance 1173.
Record 036: accepted 23 units, shipped 18 units, removed 2 damaged units, transfer inbound 3 units, checkpoint balance 1179.
Record 037: accepted 27 units, shipped 23 units, removed 4 damaged units, transfer inbound 10 units, checkpoint balance 1189.
Record 038: accepted 31 units, shipped 9 units, removed 1 damaged unit, transfer outbound 4 units, checkpoint balance 1206.
Record 039: accepted 35 units, shipped 14 units, removed 3 damaged units, transfer outbound 11 units, checkpoint balance 1213.
Record 040: accepted 39 units, shipped 19 units, removed 0 damaged units, transfer inbound 5 units, checkpoint balance 1238.
Record 041: accepted 20 units, shipped 24 units, removed 2 damaged units, transfer inbound 12 units, checkpoint balance 1244.
Record 042: accepted 24 units, shipped 10 units, removed 4 damaged units, transfer outbound 6 units, checkpoint balance 1248.
Record 043: accepted 28 units, shipped 15 units, removed 1 damaged unit, transfer outbound 13 units, checkpoint balance 1247.
Record 044: accepted 32 units, shipped 20 units, removed 3 damaged units, transfer inbound 7 units, checkpoint balance 1263.
Record 045: accepted 36 units, shipped 25 units, removed 0 damaged units, transfer inbound 14 units, checkpoint balance 1288.
Record 046: accepted 17 units, shipped 11 units, removed 2 damaged units, transfer outbound 8 units, checkpoint balance 1284.
Record 047: accepted 21 units, shipped 16 units, removed 4 damaged units, transfer outbound 15 units, checkpoint balance 1270.
Record 048: accepted 25 units, shipped 21 units, removed 1 damaged unit, transfer inbound 9 units, checkpoint balance 1282.
Record 049: accepted 29 units, shipped 26 units, removed 3 damaged units, transfer inbound 3 units, checkpoint balance 1285.
Record 050: accepted 33 units, shipped 12 units, removed 0 damaged units, transfer outbound 10 units, checkpoint balance 1296.
Record 051: accepted 37 units, shipped 17 units, removed 2 damaged units, transfer outbound 4 units, checkpoint balance 1310.
Record 052: accepted 18 units, shipped 22 units, removed 4 damaged units, transfer inbound 11 units, checkpoint balance 1313.
Record 053: accepted 22 units, shipped 27 units, removed 1 damaged unit, transfer inbound 5 units, checkpoint balance 1312.
Record 054: accepted 26 units, shipped 13 units, removed 3 damaged units, transfer outbound 12 units, checkpoint balance 1310.
Record 055: accepted 30 units, shipped 18 units, removed 0 damaged units, transfer outbound 6 units, checkpoint balance 1316.
Record 056: accepted 34 units, shipped 23 units, removed 2 damaged units, transfer inbound 13 units, checkpoint balance 1338.
Record 057: accepted 38 units, shipped 9 units, removed 4 damaged units, transfer inbound 7 units, checkpoint balance 1370.
Record 058: accepted 19 units, shipped 14 units, removed 1 damaged unit, transfer outbound 14 units, checkpoint balance 1360.
Record 059: accepted 23 units, shipped 19 units, removed 3 damaged units, transfer outbound 8 units, checkpoint balance 1353.
Record 060: accepted 27 units, shipped 24 units, removed 0 damaged units, transfer inbound 15 units, checkpoint balance 1371.
Record 061: accepted 31 units, shipped 10 units, removed 2 damaged units, transfer inbound 9 units, checkpoint balance 1399.
Record 062: accepted 35 units, shipped 15 units, removed 4 damaged units, transfer outbound 3 units, checkpoint balance 1412.
Record 063: accepted 39 units, shipped 20 units, removed 1 damaged unit, transfer outbound 10 units, checkpoint balance 1420.
Record 064: accepted 20 units, shipped 25 units, removed 3 damaged units, transfer inbound 4 units, checkpoint balance 1416.
Record 065: accepted 24 units, shipped 11 units, removed 0 damaged units, transfer inbound 11 units, checkpoint balance 1440.
Record 066: accepted 28 units, shipped 16 units, removed 2 damaged units, transfer outbound 5 units, checkpoint balance 1445.
Record 067: accepted 32 units, shipped 21 units, removed 4 damaged units, transfer outbound 12 units, checkpoint balance 1440.
Record 068: accepted 36 units, shipped 26 units, removed 1 damaged unit, transfer inbound 6 units, checkpoint balance 1455.
Record 069: accepted 17 units, shipped 12 units, removed 3 damaged units, transfer inbound 13 units, checkpoint balance 1470.
Record 070: accepted 21 units, shipped 17 units, removed 0 damaged units, transfer outbound 7 units, checkpoint balance 1467.
Record 071: accepted 25 units, shipped 22 units, removed 2 damaged units, transfer outbound 14 units, checkpoint balance 1454.
Record 072: accepted 29 units, shipped 27 units, removed 4 damaged units, transfer inbound 8 units, checkpoint balance 1460.
Record 073: accepted 33 units, shipped 13 units, removed 1 damaged unit, transfer inbound 15 units, checkpoint balance 1494.
Record 074: accepted 37 units, shipped 18 units, removed 3 damaged units, transfer outbound 9 units, checkpoint balance 1501.
Record 075: accepted 18 units, shipped 23 units, removed 0 damaged units, transfer outbound 3 units, checkpoint balance 1493.
Record 076: accepted 22 units, shipped 9 units, removed 2 damaged units, transfer inbound 10 units, checkpoint balance 1514.
Record 077: accepted 26 units, shipped 14 units, removed 4 damaged units, transfer inbound 4 units, checkpoint balance 1526.
Record 078: accepted 30 units, shipped 19 units, removed 1 damaged unit, transfer outbound 11 units, checkpoint balance 1525.
Record 079: accepted 34 units, shipped 24 units, removed 3 damaged units, transfer outbound 5 units, checkpoint balance 1527.
Record 080: accepted 38 units, shipped 10 units, removed 0 damaged units, transfer inbound 12 units, checkpoint balance 1567.

Final instruction: Audit the records above. Explain whether the checkpoints are consistent, compute the final balance, and give a short answer.'

json_prompt=${PROMPT//\\/\\\\}
json_prompt=${json_prompt//\"/\\\"}
json_prompt=${json_prompt//$'\n'/\\n}

curl "http://${HOST}:${PORT}/v1/completions" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL_PATH}\",\"prompt\":\"${json_prompt}\",\"max_tokens\":${MAX_TOKENS},\"temperature\":0}"
