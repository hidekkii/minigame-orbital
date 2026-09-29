// Leaderboard API behind CloudFront (/api/scores).
//   GET  /api/scores                       -> { scores: [{ initials, score }] }  (top 5)
//   POST /api/scores { initials, score }   -> { scores, placed }                 (saves if it makes the top 5)
import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient, QueryCommand, PutCommand } from '@aws-sdk/lib-dynamodb';

const db = DynamoDBDocumentClient.from(new DynamoDBClient({}));
const TABLE = process.env.TABLE_NAME;
const TOP = 5;
const MAX_SCORE = 5000; // sanity cap; a very long run scores a few hundred

const json = (statusCode, body) => ({
  statusCode,
  headers: { 'content-type': 'application/json', 'cache-control': 'no-store' },
  body: JSON.stringify(body),
});

async function top() {
  const { Items = [] } = await db.send(new QueryCommand({
    TableName: TABLE,
    KeyConditionExpression: 'pk = :pk',
    ExpressionAttributeValues: { ':pk': 'global' },
    ScanIndexForward: false, // sk starts with the zero-padded score, so this is highest first
    Limit: TOP,
  }));
  return Items.map(({ initials, score, sk }) => ({ initials, score, id: sk }));
}

export const handler = async (event) => {
  const method = event.requestContext?.http?.method;
  if (event.rawPath !== '/api/scores') return json(404, { error: 'not found' });

  if (method === 'GET') return json(200, { scores: await top() });
  if (method !== 'POST') return json(405, { error: 'method not allowed' });

  let input;
  try {
    input = JSON.parse(event.isBase64Encoded ? Buffer.from(event.body, 'base64').toString() : event.body);
  } catch {
    return json(400, { error: 'invalid json' });
  }
  const initials = String(input?.initials ?? '').toUpperCase();
  const score = input?.score;
  if (!/^[A-Z]{3}$/.test(initials)) return json(400, { error: 'initials must be 3 letters' });
  if (!Number.isInteger(score) || score < 1 || score > MAX_SCORE) return json(400, { error: 'invalid score' });

  const current = await top();
  if (current.length >= TOP && score <= current[TOP - 1].score) {
    return json(200, { scores: current, placed: false });
  }

  // Ties: earlier submissions rank higher, so invert the timestamp inside the sort key.
  const sk = `${String(score).padStart(6, '0')}#${String(9e12 - Date.now()).padStart(13, '0')}#${Math.random().toString(36).slice(2, 8)}`;
  await db.send(new PutCommand({
    TableName: TABLE,
    Item: { pk: 'global', sk, initials, score, createdAt: new Date().toISOString() },
  }));
  return json(200, { scores: await top(), placed: true, id: sk });
};
