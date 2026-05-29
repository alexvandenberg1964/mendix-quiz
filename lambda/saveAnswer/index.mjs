import { DynamoDBClient, GetItemCommand, UpdateItemCommand } from "@aws-sdk/client-dynamodb";
import { marshall, unmarshall } from "@aws-sdk/util-dynamodb";

const db = new DynamoDBClient({});

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "Content-Type",
  "Content-Type": "application/json"
};

export const handler = async (event) => {
  if (event.requestContext?.http?.method === "OPTIONS") {
    return { statusCode: 200, headers: cors, body: "" };
  }

  let body;
  try {
    body = JSON.parse(event.body ?? "{}");
  } catch {
    return { statusCode: 400, headers: cors, body: JSON.stringify({ error: "Invalid JSON body" }) };
  }

  const { email, questionId, answerIndex } = body;
  const today = new Date().toISOString().split("T")[0];

  if (!email || !questionId || answerIndex === undefined) {
    return { statusCode: 400, headers: cors, body: JSON.stringify({ error: "email, questionId and answerIndex are required" }) };
  }

  try {
    // Look up the correct answer (server-side validation — never trust the client)
    const qRes = await db.send(new GetItemCommand({
      TableName: process.env.QUESTIONS_TABLE,
      Key: marshall({ questionId })
    }));

    if (!qRes.Item) {
      return { statusCode: 404, headers: cors, body: JSON.stringify({ error: "Question not found" }) };
    }

    const q = unmarshall(qRes.Item);
    const correctIndex = q.correctIndex;
    const isCorrect = Number(answerIndex) === Number(correctIndex);

    // Update the participant row for today
    await db.send(new UpdateItemCommand({
      TableName: process.env.PARTICIPANTS_TABLE,
      Key: marshall({ email, date: today }),
      UpdateExpression: "SET answered = :t, answerIndex = :a, correct = :c, answeredAt = :ts",
      ExpressionAttributeValues: marshall({
        ":t": true,
        ":a": Number(answerIndex),
        ":c": isCorrect,
        ":ts": new Date().toISOString()
      })
    }));

    return {
      statusCode: 200,
      headers: cors,
      body: JSON.stringify({
        correct: isCorrect,
        correctIndex,
        explanation: q.explanation ?? null
      })
    };

  } catch (err) {
    console.error(err);
    return { statusCode: 500, headers: cors, body: JSON.stringify({ error: "Internal error" }) };
  }
};
