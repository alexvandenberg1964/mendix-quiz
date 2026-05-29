# PostNL Mendix Daily Quiz

One new Mendix question per participant per day. Each user gets a random question they haven't seen before, answers it, sees the explanation, and can leave feedback.

---

## Architecture

| Layer | Technology |
|-------|------------|
| Frontend | Single `index.html` (no build step) — deployed to GitHub Pages |
| Backend | AWS API Gateway (HTTP API) → Lambda → DynamoDB |
| Region | `eu-west-1` (Ireland) |

### AWS resources

| Resource | Name |
|----------|------|
| DynamoDB table | `quiz-questions` — question bank |
| DynamoDB table | `quiz-participants` — one row per (email, date), tracks answered questions |
| DynamoDB table | `quiz-feedback` — star ratings and comments |
| Lambda | `quiz-getQuestion` — assigns and returns today's question per participant |
| Lambda | `quiz-saveAnswer` — validates answer server-side, returns result |
| Lambda | `quiz-saveFeedback` — stores star rating + optional comment |
| API Gateway | `quiz-api` — HTTP API with CORS enabled |

The correct answer is **never sent to the client** — validation happens in `quiz-saveAnswer`.

---

## How it works

1. User enters their PostNL email address.
2. `GET /question?email=...` — Lambda picks a random unseen question for this participant and reserves it for today.
3. User selects an option and submits — `POST /answer` validates the answer and returns the result + explanation.
4. After answering, the user can rate the question 1–5 stars and leave a comment — `POST /feedback`.
5. Returning tomorrow: the same email gets a fresh unseen question.
6. When all questions are exhausted the app shows a "well done" completion screen.

---

## Question bank

- **160 questions** across 56 Mendix categories
- Stored in DynamoDB; managed locally via `questions.json`
- Seeded to AWS with `seed-questions.sh`

### Question format (`questions.json`)

```json
{
  "questionId": "q001",
  "category": "Mendix Basics",
  "text": "Your question text?",
  "options": ["Option A", "Option B", "Option C", "Option D", "Option E"],
  "correctIndex": 2,
  "explanation": "Shown after the participant answers.",
  "difficulty": "easy",
  "active": true
}
```

`correctIndex` is zero-based (0 = A, 1 = B, …, 4 = E). Set `active: false` to hide a question without deleting it.

---

## API

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/question?email=you@postnl.nl` | Get today's question for a participant |
| `POST` | `/answer` | Submit an answer |
| `POST` | `/feedback` | Submit a star rating (1–5) and optional comment |

Current endpoint (hardcoded in `index.html`):
```
https://4kklbjjir4.execute-api.eu-west-1.amazonaws.com/prod
```

---

## Deployment

### Prerequisites

- AWS CLI v2 configured (`aws configure`)
- Node.js 22+
- `jq` and `python3` (for seeding)
- Bash (Git Bash or WSL on Windows)

### First-time setup

```bash
# 1. Deploy all AWS infrastructure
chmod +x deploy.sh
./deploy.sh
# The API endpoint is printed at the end and saved to .api-endpoint

# 2. Update the API endpoint in index.html if it changed
#    Find this line near the top of the <script> section:
#    const API = 'https://...execute-api.eu-west-1.amazonaws.com/prod';
#    Replace it with the value from .api-endpoint

# 3. Seed questions into DynamoDB
chmod +x seed-questions.sh
./seed-questions.sh questions.json

# 4. Push index.html to GitHub Pages
git add index.html
git commit -m "Update API endpoint"
git push
```

GitHub Pages serves the quiz at:
```
https://YOUR-GITHUB-USERNAME.github.io/mendix-quiz
```

### Updating questions

Edit `questions.json` and re-run the seed script. The script uses Python to build the DynamoDB `put-item` calls, so no shell quoting issues with special characters.

```bash
./seed-questions.sh questions.json
```

To deactivate a question without deleting it, set `"active": false` in the JSON and re-seed.

### Tear down

```bash
chmod +x teardown.sh
./teardown.sh
```

This deletes the API Gateway, all three Lambda functions, the IAM role, and all three DynamoDB tables.

---

## File overview

```
index.html          — self-contained frontend SPA
questions.json      — full question bank (source of truth)
seed-questions.sh   — bulk-loads questions.json into DynamoDB
deploy.sh           — creates all AWS resources from scratch
teardown.sh         — removes all AWS resources
iam-trust-policy.json   — Lambda execution role trust policy
iam-dynamo-policy.json  — inline DynamoDB access policy
lambda/
  getQuestion/index.mjs
  saveAnswer/index.mjs
  saveFeedback/index.mjs
.api-endpoint       — written by deploy.sh; contains the live API URL
```
