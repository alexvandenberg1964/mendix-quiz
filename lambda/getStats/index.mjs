import { DynamoDBClient, ScanCommand } from "@aws-sdk/client-dynamodb";
import { unmarshall } from "@aws-sdk/util-dynamodb";

const db = new DynamoDBClient({});

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "Content-Type, x-admin-key",
  "Content-Type": "application/json"
};

export const handler = async (event) => {
  if (event.requestContext?.http?.method === "OPTIONS") {
    return { statusCode: 200, headers: cors, body: "" };
  }

  const adminKey = event.headers?.["x-admin-key"];
  if (!adminKey || adminKey !== process.env.ADMIN_KEY) {
    return { statusCode: 401, headers: cors, body: JSON.stringify({ error: "Unauthorized" }) };
  }

  try {
    const [participantsRes, questionsRes, feedbackRes] = await Promise.all([
      db.send(new ScanCommand({ TableName: process.env.PARTICIPANTS_TABLE })),
      db.send(new ScanCommand({ TableName: process.env.QUESTIONS_TABLE })),
      db.send(new ScanCommand({ TableName: process.env.FEEDBACK_TABLE }))
    ]);

    const participantRows = (participantsRes.Items ?? []).map(unmarshall);
    const questions = (questionsRes.Items ?? []).map(unmarshall);
    const feedback = (feedbackRes.Items ?? []).map(unmarshall);

    const questionMap = {};
    for (const q of questions) questionMap[q.questionId] = q;
    const activeQuestionCount = questions.filter(q => q.active).length;

    const answered = participantRows.filter(r => r.answered);
    const uniqueParticipants = new Set(participantRows.map(r => r.email));
    const totalAnswers = answered.length;
    const totalCorrect = answered.filter(r => r.correct).length;
    const accuracyPct = totalAnswers > 0 ? round1(totalCorrect / totalAnswers * 100) : 0;
    const avgRating = feedback.length > 0
      ? round1(feedback.reduce((s, f) => s + f.rating, 0) / feedback.length)
      : 0;

    // Daily activity
    const byDate = {};
    for (const r of answered) {
      if (!byDate[r.date]) byDate[r.date] = { date: r.date, answers: 0, participants: new Set() };
      byDate[r.date].answers++;
      byDate[r.date].participants.add(r.email);
    }
    const dailyActivity = Object.values(byDate)
      .map(d => ({ date: d.date, answers: d.answers, participants: d.participants.size }))
      .sort((a, b) => a.date.localeCompare(b.date));

    // Category / difficulty breakdown
    const catMap = {};
    const diffMap = {};
    for (const r of answered) {
      const q = questionMap[r.questionId];
      if (!q) continue;
      const cat = q.category || "Uncategorized";
      const diff = q.difficulty || "Unknown";
      bump(catMap, cat, r.correct);
      bump(diffMap, diff, r.correct);
    }
    const categoryBreakdown = toBreakdown(catMap, "category");
    const difficultyBreakdown = toBreakdown(diffMap, "difficulty");

    // Hardest questions (lowest accuracy, min sample size to avoid noise)
    const qStats = {};
    for (const r of answered) {
      if (!qStats[r.questionId]) qStats[r.questionId] = { total: 0, correct: 0 };
      qStats[r.questionId].total++;
      if (r.correct) qStats[r.questionId].correct++;
    }
    const hardestQuestions = Object.entries(qStats)
      .filter(([, v]) => v.total >= 3)
      .map(([questionId, v]) => ({
        questionId,
        text: questionMap[questionId]?.text ?? "(deleted question)",
        category: questionMap[questionId]?.category ?? "",
        total: v.total,
        correct: v.correct,
        accuracyPct: round1(v.correct / v.total * 100)
      }))
      .sort((a, b) => a.accuracyPct - b.accuracyPct)
      .slice(0, 10);

    // Completion: participants who've answered every active question
    const perEmailAnswered = {};
    for (const r of answered) {
      if (!perEmailAnswered[r.email]) perEmailAnswered[r.email] = new Set();
      perEmailAnswered[r.email].add(r.questionId);
    }
    let finished = 0;
    for (const email of uniqueParticipants) {
      if (activeQuestionCount > 0 && (perEmailAnswered[email]?.size ?? 0) >= activeQuestionCount) finished++;
    }

    return {
      statusCode: 200,
      headers: cors,
      body: JSON.stringify({
        totals: {
          participants: uniqueParticipants.size,
          answers: totalAnswers,
          accuracyPct,
          feedbackCount: feedback.length,
          avgRating,
          activeQuestions: activeQuestionCount
        },
        completion: { finished, inProgress: uniqueParticipants.size - finished },
        dailyActivity,
        categoryBreakdown,
        difficultyBreakdown,
        hardestQuestions,
        updatedAt: new Date().toISOString()
      })
    };
  } catch (err) {
    console.error(err);
    return { statusCode: 500, headers: cors, body: JSON.stringify({ error: "Internal error" }) };
  }
};

const round1 = (n) => Math.round(n * 10) / 10;

const bump = (map, key, correct) => {
  if (!map[key]) map[key] = { total: 0, correct: 0 };
  map[key].total++;
  if (correct) map[key].correct++;
};

const toBreakdown = (map, keyName) =>
  Object.entries(map)
    .map(([key, v]) => ({ [keyName]: key, total: v.total, correct: v.correct, accuracyPct: round1(v.correct / v.total * 100) }))
    .sort((a, b) => b.total - a.total);
