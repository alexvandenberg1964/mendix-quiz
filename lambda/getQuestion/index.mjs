import { DynamoDBClient, ScanCommand, GetItemCommand, PutItemCommand } from "@aws-sdk/client-dynamodb";
import { marshall, unmarshall } from "@aws-sdk/util-dynamodb";

const db = new DynamoDBClient({});

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "Content-Type",
  "Content-Type": "application/json"
};

export const handler = async (event) => {
  const email = event.queryStringParameters?.email;
  const today = new Date().toISOString().split("T")[0];

  if (!email) {
    return { statusCode: 400, headers: cors, body: JSON.stringify({ error: "email is required" }) };
  }
  if (!email.toLowerCase().endsWith("@postnl.nl")) {
    return { statusCode: 403, headers: cors, body: JSON.stringify({ error: "Only @postnl.nl email addresses are allowed" }) };
  }

  try {
    // Check if participant already has a question assigned for today
    const existing = await db.send(new GetItemCommand({
      TableName: process.env.PARTICIPANTS_TABLE,
      Key: marshall({ email, date: today })
    }));

    if (existing.Item) {
      const row = unmarshall(existing.Item);
      // Fetch the question details (without the correct answer)
      const qRes = await db.send(new GetItemCommand({
        TableName: process.env.QUESTIONS_TABLE,
        Key: marshall({ questionId: row.questionId })
      }));
      const q = unmarshall(qRes.Item);
      return {
        statusCode: 200,
        headers: cors,
        body: JSON.stringify({
          question: sanitize(q),
          alreadyAnswered: row.answered ?? false,
          selectedIndex: row.answered ? (row.answerIndex ?? null) : null,
          correct: row.answered ? (row.correct ?? null) : null,
          correctIndex: row.answered ? q.correctIndex : null,
          explanation: row.answered ? q.explanation : null
        })
      };
    }

    // Get all questionIds this participant has already seen
    const historyRes = await db.send(new ScanCommand({
      TableName: process.env.PARTICIPANTS_TABLE,
      FilterExpression: "email = :e",
      ExpressionAttributeValues: marshall({ ":e": email }),
      ProjectionExpression: "questionId"
    }));
    const seen = new Set((historyRes.Items ?? []).map(i => unmarshall(i).questionId));

    // Scan all active questions and filter out already-seen ones
    const allQsRes = await db.send(new ScanCommand({
      TableName: process.env.QUESTIONS_TABLE,
      FilterExpression: "#active = :t",
      ExpressionAttributeNames: { "#active": "active" },
      ExpressionAttributeValues: marshall({ ":t": true })
    }));

    const pool = (allQsRes.Items ?? [])
      .map(i => unmarshall(i))
      .filter(q => !seen.has(q.questionId));

    if (pool.length === 0) {
      return {
        statusCode: 200,
        headers: cors,
        body: JSON.stringify({ done: true, message: "You have completed all available questions — well done!" })
      };
    }

    // Pick a random unseen question
    const q = pool[Math.floor(Math.random() * pool.length)];

    // Reserve this question for the participant today (unanswered placeholder)
    await db.send(new PutItemCommand({
      TableName: process.env.PARTICIPANTS_TABLE,
      Item: marshall({ email, date: today, questionId: q.questionId, answered: false })
    }));

    return {
      statusCode: 200,
      headers: cors,
      body: JSON.stringify({ question: sanitize(q) })
    };

  } catch (err) {
    console.error(err);
    return { statusCode: 500, headers: cors, body: JSON.stringify({ error: "Internal error" }) };
  }
};

// Strip correctIndex and explanation so the client cannot cheat
const sanitize = (q) => ({
  questionId: q.questionId,
  text: q.text,
  options: q.options,
  category: q.category,
  difficulty: q.difficulty
});
