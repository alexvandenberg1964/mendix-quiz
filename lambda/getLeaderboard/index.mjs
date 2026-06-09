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

    // Sort: pct desc, then correct desc (more answers wins tie)
    const board = Object.values(map)
      .map(e => ({ ...e, pct: e.total > 0 ? Math.round((e.correct / e.total) * 100) : 0 }))
      .sort((a, b) => b.pct - a.pct || b.correct - a.correct)
      .slice(0, 20)
      .map((e, i) => ({
        rank: i + 1,
        name: nameFromEmail(e.email),
        email: e.email,
        total: e.total,
        correct: e.correct,
        streak: e.streak,
        pct: e.pct
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
