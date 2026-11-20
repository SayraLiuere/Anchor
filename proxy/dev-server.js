// Local test server for the proxy: runs the same Worker code with an
// in-memory counter. Without an API key it fakes the AI service, so the app
// can be tested end to end with no account and no cost.
//
//   cd proxy && node dev-server.js                       # fake replies, limit 50
//   DAILY_LIMIT=3 node dev-server.js                     # see the limit quickly
//   OPENAI_KEY=sk-... node dev-server.js                 # real OpenAI calls
//   UPSTREAM=openrouter OPENROUTER_KEY=sk-or-... DEFAULT_MODEL=openai/gpt-4.1-mini \
//     ALLOWED_MODELS=openai/gpt-4.1-mini node dev-server.js   # real OpenRouter calls
//
// From the Android emulator the server is http://10.0.2.2:8787 (build the app
// with --dart-define=ANCHOR_PROXY_URL=http://10.0.2.2:8787).
import { createServer } from 'node:http';
import { handle, UPSTREAMS } from './src/worker.js';

const upstream = process.env.UPSTREAM ?? 'openai';
const keyVar = UPSTREAMS[upstream]?.keyVar;
const realKey = keyVar ? process.env[keyVar] : undefined;

const store = new Map();
const env = {
  UPSTREAM: upstream,
  // A placeholder key lets the fake service pass the "is it set up" check.
  ...(keyVar ? { [keyVar]: realKey || 'fake-key' } : {}),
  DEFAULT_MODEL: process.env.DEFAULT_MODEL ?? 'gpt-4.1-mini',
  ALLOWED_MODELS: process.env.ALLOWED_MODELS ?? 'gpt-4.1-mini',
  DAILY_LIMIT: process.env.DAILY_LIMIT ?? '50',
  USAGE: { get: async (k) => store.get(k) ?? null, put: async (k, v) => void store.set(k, v) },
};

const fakeService = async (_url, init) => {
  const { model, messages } = JSON.parse(init.body);
  const last = messages.at(-1).content.slice(0, 40);
  return new Response(JSON.stringify({
    choices: [{ message: { role: 'assistant', content: `(dev proxy, ${model}) You said: "${last}"` } }],
  }), { status: 200 });
};

createServer(async (req, res) => {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  const request = new Request(`http://localhost${req.url}`, {
    method: req.method,
    headers: req.headers,
    body: req.method === 'POST' ? Buffer.concat(chunks) : undefined,
  });
  const response = await handle(request, env, realKey ? {} : { fetchImpl: fakeService });
  // Status only: never print message content.
  console.log(`${new Date().toISOString()} ${req.method} ${req.url} -> ${response.status}`);
  res.writeHead(response.status, Object.fromEntries(response.headers));
  res.end(Buffer.from(await response.arrayBuffer()));
}).listen(8787, () => console.log(
  `Anchor proxy (dev) on http://localhost:8787, ${realKey ? `real ${upstream}` : 'fake replies'}, limit ${env.DAILY_LIMIT}/day`));
