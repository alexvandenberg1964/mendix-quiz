import { DynamoDBClient, ScanCommand } from "@aws-sdk/client-dynamodb";
import { unmarshall } from "@aws-sdk/util-dynamodb";

const db = new DynamoDBClient({});

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "Content-Type",
  "Content-Type": "application/json"
};

export const handler = async () => {
  try {
    // Scan all answered rows
    const result = await db.send(new ScanCommand({
      TableName: process.env.PARTICIPANTS_TABLE,
      FilterExpression: "answered = :t",
      ExpressionAttributeValues: { ":t": { BOOL: true } }
    }));

    // Aggregate per email
    const map = {};
    for (const raw of (result.Items ?? [])) {
      const row = unmarshall(raw);
      const email = row.email;
      if (!map[email]) {
        map[email] = { email, total: 0, correct: 0, streak: 0, dates: [] };
      }
      map[email].total++;
      if (row.correct) map[email].correct++;
      map[email].dates.push(row.date);
    }

    // Calculate streak (consecutive days up to today)
    const today = new Date().toISOString().split("T")[0];
    for (const entry of Object.values(map)) {
      entry.dates.sort().reverse();
      let streak = 0;
      let cursor = today;
      for (const date of entry.dates) {
        if (date === cursor) {
          streak++;
          // Move cursor back one day
          const d = new Date(cursor);
          d.setDate(d.getDate() - 1);
          cursor = d.toISOString().split("T")[0];
        } else if (date < cursor) {
          break;
        }
      }
      entry.streak = streak;
      delete entry.dates;
    }

    // Sort by Wilson score lower bound: a confidence-adjusted correctness rate
    // that discounts small sample sizes, so 1/1 doesn't outrank 18/20.
    const board = Object.values(map)
      .map(e => ({ ...e, score: Math.round(wilsonScore(e.correct, e.total) * 100) }))
      .sort((a, b) => b.score - a.score || b.correct - a.correct)
      .slice(0, 20)
      .map((e, i) => ({
        rank: i + 1,
        name: nameFromEmail(e.email),
        email: e.email,
        total: e.total,
        correct: e.correct,
        streak: e.streak,
        score: e.score
      }));

    return {
      statusCode: 200,
      headers: cors,
      body: JSON.stringify({ board, updatedAt: new Date().toISOString() })
    };
  } catch (err) {
    console.error(err);
    return { statusCode: 500, headers: cors, body: JSON.stringify({ error: "Internal error" }) };
  }
};

// Wilson score lower bound (95% confidence) for a binomial proportion.
// Shrinks the score toward 0 when total is small, so a lucky 1/1 scores
// lower than a proven 18/20 rather than tying it at the top.
const wilsonScore = (correct, total) => {
  if (total === 0) return 0;
  const z = 1.96;
  const p = correct / total;
  const n = total;
  return (p + z * z / (2 * n) - z * Math.sqrt((p * (1 - p) + z * z / (4 * n)) / n)) / (1 + z * z / n);
};

// "alex.van.den.berg@postnl.nl" -> "Alex van den Berg"
const nameFromEmail = (email) => {
  const local = email.split("@")[0];
  return local
    .split(".")
    .map((part, i) => {
      // Keep tussenvoegsel lowercase: van, den, de, van der, etc.
      const tussenvoegsels = ["van", "den", "de", "der", "het", "ten", "ter", "op", "in"];
      if (i > 0 && tussenvoegsels.includes(part.toLowerCase())) return part.toLowerCase();
      return part.charAt(0).toUpperCase() + part.slice(1);
    })
    .join(" ");
};
