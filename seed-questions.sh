#!/usr/bin/env bash
# =============================================================================
# seed-questions.sh — Bulk import questions from questions.json
# Uses Python for safe JSON serialization — no shell quoting issues.
#
# Usage:
#   ./seed-questions.sh questions.json
# =============================================================================

set -euo pipefail

REGION="eu-west-1"
TABLE="quiz-questions"
FILE="${1:-questions.json}"

if [ ! -f "$FILE" ]; then
  echo "Error: $FILE not found"
  echo "Usage: ./seed-questions.sh questions.json"
  exit 1
fi

# Check python3 is available
if ! command -v python3 &>/dev/null; then
  echo "Error: python3 is required but not installed."
  exit 1
fi

python3 - "$FILE" "$TABLE" "$REGION" << 'PYEOF'
import json
import subprocess
import sys

file    = sys.argv[1]
table   = sys.argv[2]
region  = sys.argv[3]

with open(file, encoding='utf-8') as f:
    questions = json.load(f)

total = len(questions)
errors = []

for i, q in enumerate(questions):
    # Build the DynamoDB item dict using Python — handles all special chars safely
    item = {
        "questionId":  {"S": q["questionId"]},
        "category":    {"S": q["category"]},
        "text":        {"S": q["text"]},
        "options":     {"L": [{"S": opt} for opt in q["options"]]},
        "correctIndex":{"N": str(q["correctIndex"])},
        "explanation": {"S": q["explanation"]},
        "difficulty":  {"S": q.get("difficulty", "medium")},
        "active":      {"BOOL": q.get("active", True)},
    }

    item_json = json.dumps(item)   # Python handles all escaping correctly

    result = subprocess.run(
        [
            "aws", "dynamodb", "put-item",
            "--table-name", table,
            "--item", item_json,
            "--region", region,
            "--profile" , "sandbox-851725425406",
            "--no-cli-pager",
        ],
        capture_output=True,
        text=True,
    )

    if result.returncode != 0:
        print(f"  [{i+1}/{total}] ERROR {q['questionId']}: {result.stderr.strip()}")
        errors.append(q["questionId"])
    else:
        print(f"  [{i+1}/{total}] OK    {q['questionId']}  —  {q['category']}")

print()
if errors:
    print(f"Done with {len(errors)} error(s): {', '.join(errors)}")
    sys.exit(1)
else:
    print(f"All {total} questions imported successfully.")
PYEOF
