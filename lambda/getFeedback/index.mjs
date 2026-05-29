import { DynamoDBClient, ScanCommand, BatchGetItemCommand } from "@aws-sdk/client-dynamodb";
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

  const filterQuestionId = event.queryStringParameters?.questionId ?? null;

  try {
    const scanParams = { TableName: process.env.FEEDBACK_TABLE };
    if (filterQuestionId) {
      scanParams.FilterExpression = "questionId = :q";
      scanParams.ExpressionAttributeValues = marshall({ ":q": filterQuestionId });
    }

    const feedbackRes = await db.send(new ScanCommand(scanParams));
    const allFeedback = (feedbackRes.Items ?? []).map(i => unmarshall(i));

    // Group by questionId
    const byQuestion = {};
    for (const fb of allFeedback) {
      if (!byQuestion[fb.questionId]) byQuestion[fb.questionId] = [];
      byQuestion[fb.questionId].push(fb);
    }

    const questionIds = Object.keys(byQuestion);
    const questionMap = {};

    // Batch-fetch question metadata (max 100 keys per request)
    for (let i = 0; i < questionIds.length; i += 100) {
      const chunk = questionIds.slice(i, i + 100);
      const batchRes = await db.send(new BatchGetItemCommand({
        RequestItems: {
          [process.env.QUESTIONS_TABLE]: {
            Keys: chunk.map(id => marshall({ questionId: id })),
            ProjectionExpression: "questionId, #t, category, difficulty",
            ExpressionAttributeNames: { "#t": "text" }
          }
        }
      }));
      for (const item of (batchRes.Responses?.[process.env.QUESTIONS_TABLE] ?? [])) {
        const q = unmarshall(item);
        questionMap[q.questionId] = q;
      }
    }

    const questions = questionIds.map(qid => {
      const feedbacks = byQuestion[qid];
      const avgRating = feedbacks.reduce((s, f) => s + f.rating, 0) / feedbacks.length;
      const q = questionMap[qid] ?? {};
      return {
        questionId: qid,
        text: q.text ?? "(question not found)",
        category: q.category ?? "",
        difficulty: q.difficulty ?? "",
        avgRating: Math.round(avgRating * 10) / 10,
        totalResponses: feedbacks.length,
        feedback: feedbacks
          .sort((a, b) => new Date(b.submittedAt) - new Date(a.submittedAt))
          .map(({ email, rating, comment, submittedAt }) => ({ email, rating, comment, submittedAt }))
      };
    }).sort((a, b) => a.avgRating - b.avgRating);

    return {
      statusCode: 200,
      headers: cors,
      body: JSON.stringify({ questions, totalFeedback: allFeedback.length })
    };

  } catch (err) {
    console.error(err);
    return { statusCode: 500, headers: cors, body: JSON.stringify({ error: "Internal error" }) };
  }
};
