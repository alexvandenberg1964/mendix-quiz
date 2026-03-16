# PostNL Mendix Engineer Quiz — Setup Guide

## What's in the box
- `index.html` — the complete quiz app (80 questions, 16 weeks, 5 options each)
- Live leaderboard powered by Supabase
- Admin view at `?admin=true`
- Works without Supabase too (falls back to browser localStorage)

---

## Step 1 — Create a free Supabase project

1. Go to https://supabase.com and click **Start your project** (free account)
2. Click **New project**, give it a name like `mendix-quiz`, choose a region close to the Netherlands (e.g. Frankfurt)
3. Set a database password (save it somewhere safe) and click **Create new project**
4. Wait ~1 minute for the project to be ready

---

## Step 2 — Create the database table

1. In your Supabase project, click **SQL Editor** in the left sidebar
2. Paste and run this SQL:

```sql
create table quiz_submissions (
  id uuid default gen_random_uuid() primary key,
  email text not null,
  week integer not null,
  answers jsonb not null,
  submitted_at timestamptz default now(),
  unique(email, week)
);

-- Allow anyone to read and write (the quiz is internal, no login required)
alter table quiz_submissions enable row level security;

create policy "allow all reads" on quiz_submissions
  for select using (true);

create policy "allow all inserts and updates" on quiz_submissions
  for insert with check (true);

create policy "allow updates" on quiz_submissions
  for update using (true);
```

3. Click **Run** — you should see "Success. No rows returned."

---

## Step 3 — Get your Supabase credentials

1. In your Supabase project, click **Settings** (gear icon) → **API**
2. Copy two values:
   - **Project URL** (looks like `https://abcdefgh.supabase.co`)
   - **anon / public key** (a long string starting with `eyJ...`)

---

## Step 4 — Add credentials to index.html

Open `index.html` in any text editor (Notepad, VS Code, etc.) and find these two lines near the top of the `<script>` section:

```javascript
const SUPABASE_URL = 'YOUR_SUPABASE_URL';
const SUPABASE_ANON_KEY = 'YOUR_SUPABASE_ANON_KEY';
```

Replace with your actual values:

```javascript
const SUPABASE_URL = 'https://abcdefgh.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5...';
```

Save the file.

---

## Step 5 — Deploy to GitHub Pages

1. Go to https://github.com and create a free account (if you don't have one)
2. Click **+** → **New repository**, name it `mendix-quiz`, set to **Public**, check "Add README"
3. Click **Add file** → **Upload files**, drag your updated `index.html`
4. Commit the file
5. Go to **Settings** → **Pages** → Source: **Deploy from a branch** → Branch: **main** → folder: **/ (root)** → **Save**
6. After ~2 minutes your quiz is live at:

```
https://YOUR-GITHUB-USERNAME.github.io/mendix-quiz
```

---

## Usage

| URL | Purpose |
|-----|---------|
| `https://you.github.io/mendix-quiz` | Participant quiz link — share this |
| `https://you.github.io/mendix-quiz?admin=true` | Admin view — keep this private |

### Admin view includes:
- All 80 questions, correct answers, and explanations (filterable by week/category)
- All participant submissions with scores
- Full leaderboard

### Quiz rules:
- Week 1 opens **Monday March 23, 2026**
- Each week runs Monday–Sunday
- Participants can resubmit until Sunday
- Results for completed weeks visible in "My Results" tab
- Leaderboard visible to everyone at all times

---

## Updating questions

All questions are in `index.html` in the `QUESTIONS` array. Each question looks like:

```javascript
{
  week: 1,
  cat: 'Mendix Basics',
  q: 'Your question text here?',
  options: ['Option A', 'Option B', 'Option C', 'Option D', 'Option E'],
  correct: 2,          // 0 = A, 1 = B, 2 = C, 3 = D, 4 = E
  explanation: 'Explanation shown in results after the week closes.'
}
```

After editing, re-upload `index.html` to GitHub and commit. GitHub Pages will update within a minute.
