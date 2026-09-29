// Leaderboard API behind CloudFront (/api/scores).
//   GET  /api/scores                       -> { scores: [{ initials, score }] }  (top 5)
//   POST /api/scores { initials, score }   -> { scores, placed }                 (saves if it makes the top 5
//                                                                                and beats that player's best)
import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient, QueryCommand, GetCommand, TransactWriteCommand } from '@aws-sdk/lib-dynamodb';

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

  // One board entry per initials: a 'player' item remembers each player's best and where it sits on the board.
  const [current, { Item: player }] = await Promise.all([
    top(),
    db.send(new GetCommand({ TableName: TABLE, Key: { pk: 'player', sk: initials } })),
  ]);
  if (player && score <= player.best) {
    return json(200, { scores: current, placed: false, reason: 'best', best: player.best });
  }
  if (current.length >= TOP && score <= current[TOP - 1].score) {
    return json(200, { scores: current, placed: false, reason: 'low' });
  }

  // Ties: earlier submissions rank higher, so invert the timestamp inside the sort key.
  const sk = `${String(score).padStart(6, '0')}#${String(9e12 - Date.now()).padStart(13, '0')}#${Math.random().toString(36).slice(2, 8)}`;
  const writes = [
    { Put: { TableName: TABLE, Item: { pk: 'global', sk, initials, score, createdAt: new Date().toISOString() } } },
    { Put: {
      TableName: TABLE,
      Item: { pk: 'player', sk: initials, best: score, boardSk: sk },
      // Guards against two simultaneous submissions for the same initials.
      ConditionExpression: 'attribute_not_exists(pk) OR best < :score',
      ExpressionAttributeValues: { ':score': score },
    } },
  ];
  if (player?.boardSk) writes.push({ Delete: { TableName: TABLE, Key: { pk: 'global', sk: player.boardSk } } });
  try {
    await db.send(new TransactWriteCommand({ TransactItems: writes }));
  } catch (err) {
    if (err.name !== 'TransactionCanceledException') throw err;
    return json(200, { scores: await top(), placed: false, reason: 'best' });
  }
  return json(200, { scores: await top(), placed: true, id: sk });
};
