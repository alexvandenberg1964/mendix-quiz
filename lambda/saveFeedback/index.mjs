import { DynamoDBClient, PutItemCommand } from "@aws-sdk/client-dynamodb";
import { marshall } from "@aws-sdk/util-dynamodb";
import { randomUUID } from "crypto";

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

  const { email, questionId, rating, comment } = body;

  if (!email || !questionId || rating === undefined) {
    return { statusCode: 400, headers: cors, body: JSON.stringify({ error: "email, questionId and rating are required" }) };
  }
  if (!email.toLowerCase().endsWith("@postnl.nl")) {
    return { statusCode: 403, headers: cors, body: JSON.stringify({ error: "Only @postnl.nl email addresses are allowed" }) };
  }

  if (Number(rating) < 1 || Number(rating) > 5) {
    return { statusCode: 400, headers: cors, body: JSON.stringify({ error: "rating must be between 1 and 5" }) };
  }

  try {
    await db.send(new PutItemCommand({
      TableName: process.env.FEEDBACK_TABLE,
      Item: marshall({
        feedbackId: randomUUID(),
        questionId,
        email,
        rating: Number(rating),
        comment: comment?.trim() ?? "",
        submittedAt: new Date().toISOString()
      })
    }));

    return {
      statusCode: 200,
      headers: cors,
      body: JSON.stringify({ ok: true })
    };

  } catch (err) {
    console.error(err);
    return { statusCode: 500, headers: cors, body: JSON.stringify({ error: "Internal error" }) };
  }
};
