// Run with: cd proxy && node --test   (Node 18+, no packages needed)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { handle, dayKey } from '../src/worker.js';

const ID = '3f2b8c1e-9a4d-4e6f-8b2a-1c3d5e7f9a0b';

function setup(overrides = {}) {
  const store = new Map();
  const calls = [];
  const env = {
    OPENROUTER_KEY: 'sk-or-secret',
    DEFAULT_MODEL: 'openai/gpt-4.1-mini',
    ALLOWED_MODELS: 'openai/gpt-4.1-mini, google/gemini-2.5-flash',
    DAILY_LIMIT: '50',
    USAGE: {
      get: async (k) => store.get(k) ?? null,
      put: async (k, v) => void store.set(k, v),
    },
    ...overrides,
  };
  const fetchImpl = async (url, init) => {
    calls.push({ url, init, body: JSON.parse(init.body) });
    return new Response(JSON.stringify({ choices: [{ message: { content: 'hi!' } }] }), {
      status: 200,
    });
  };
  return { env, store, calls, fetchImpl };
}

const req = (body, headers = { 'x-install-id': ID }) =>
  new Request('https://proxy.example/v1/chat/completions', {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...headers },
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });

const chat = { messages: [{ role: 'system', content: 'be kind' }, { role: 'user', content: 'hey' }] };

test('forwards with the server key, the default model and no install ID', async () => {
  const s = setup();
  const res = await handle(req(chat), s.env, { fetchImpl: s.fetchImpl });
  assert.equal(res.status, 200);
  assert.equal((await res.json()).choices[0].message.content, 'hi!');
  assert.equal(res.headers.get('x-calls-left'), '49');
  const [c] = s.calls;
  assert.equal(c.url, 'https://openrouter.ai/api/v1/chat/completions');
  assert.equal(c.init.headers.authorization, 'Bearer sk-or-secret');
  assert.equal(c.body.model, 'openai/gpt-4.1-mini');
  assert.equal(c.body.max_tokens, 1500);
  assert.ok(!JSON.stringify(c).includes(ID), 'install ID must not reach OpenRouter');
  assert.deepEqual(Object.keys(c.body).sort(), ['max_tokens', 'messages', 'model']);
});

test('the 51st call of the day gets a friendly 429, and the next day resets', async () => {
  const s = setup();
  const day1 = new Date('2026-11-21T03:00:00Z');
  for (let i = 0; i < 50; i++) {
    assert.equal((await handle(req(chat), s.env, { fetchImpl: s.fetchImpl, now: day1 })).status, 200);
  }
  const res = await handle(req(chat), s.env, { fetchImpl: s.fetchImpl, now: day1 });
  assert.equal(res.status, 429);
  const err = (await res.json()).error;
  assert.equal(err.code, 'daily_limit');
  assert.match(err.message, /resets at midnight/);
  assert.equal(s.calls.length, 50, 'the 51st call is not forwarded');

  const day2 = new Date('2026-11-21T16:30:00Z'); // 00:30 the next day in UTC+8
  assert.equal((await handle(req(chat), s.env, { fetchImpl: s.fetchImpl, now: day2 })).status, 200);
});

test('limits are per install', async () => {
  const s = setup({ DAILY_LIMIT: '1' });
  assert.equal((await handle(req(chat), s.env, { fetchImpl: s.fetchImpl })).status, 200);
  assert.equal((await handle(req(chat), s.env, { fetchImpl: s.fetchImpl })).status, 429);
  const other = { 'x-install-id': '9c1d2e3f-4a5b-4c6d-9e8f-0a1b2c3d4e5f' };
  assert.equal((await handle(req(chat, other), s.env, { fetchImpl: s.fetchImpl })).status, 200);
});

test('rejects a missing or malformed install ID', async () => {
  const s = setup();
  assert.equal((await handle(req(chat, {}), s.env, { fetchImpl: s.fetchImpl })).status, 401);
  assert.equal((await handle(req(chat, { 'x-install-id': 'me' }), s.env, { fetchImpl: s.fetchImpl })).status, 401);
  assert.equal(s.calls.length, 0);
});

test('rejects models outside the allowlist, streaming and bad bodies', async () => {
  const s = setup();
  const r = async (b) => (await handle(req(b), s.env, { fetchImpl: s.fetchImpl })).status;
  assert.equal(await r({ ...chat, model: 'openai/gpt-5' }), 400);
  assert.equal(await r({ ...chat, stream: true }), 400);
  assert.equal(await r('not json'), 400);
  assert.equal(await r({ messages: [] }), 400);
  assert.equal(await r({ messages: [{ role: 'tool', content: 'x' }] }), 400);
  assert.equal(await r({ ...chat, model: 'google/gemini-2.5-flash' }), 200);
  assert.equal(s.calls.at(-1).body.model, 'google/gemini-2.5-flash');
});

test('rejects bodies over 32 KB and caps reply tokens', async () => {
  const s = setup();
  const big = { messages: [{ role: 'user', content: 'x'.repeat(33 * 1024) }] };
  assert.equal((await handle(req(big), s.env, { fetchImpl: s.fetchImpl })).status, 413);
  await handle(req({ ...chat, max_tokens: 99999 }), s.env, { fetchImpl: s.fetchImpl });
  assert.equal(s.calls.at(-1).body.max_tokens, 1500);
});

test('upstream errors return the status only, never the upstream body', async () => {
  const s = setup();
  const failing = async () => new Response('{"echo":"hey"}', { status: 401 });
  const res = await handle(req(chat), s.env, { fetchImpl: failing });
  assert.equal(res.status, 502);
  const text = await res.text();
  assert.match(text, /returned 401/);
  assert.ok(!text.includes('echo'));
});

test('other paths are 404 and /health is ok', async () => {
  const s = setup();
  const get = (p) => handle(new Request(`https://proxy.example${p}`), s.env);
  assert.equal((await get('/health')).status, 200);
  assert.equal((await get('/v1/models')).status, 404);
});

test('the day rolls over at local midnight (UTC+8 by default)', () => {
  assert.equal(dayKey(new Date('2026-11-21T15:59:00Z'), 480), '2026-11-21');
  assert.equal(dayKey(new Date('2026-11-21T16:00:00Z'), 480), '2026-11-22');
});

const openaiEnv = {
  UPSTREAM: 'openai',
  OPENAI_KEY: 'sk-openai-secret',
  OPENROUTER_KEY: undefined,
  DEFAULT_MODEL: 'gpt-4.1-mini',
  ALLOWED_MODELS: 'gpt-4.1-mini',
};

test('UPSTREAM=openai goes straight to OpenAI with its key and token field', async () => {
  const s = setup(openaiEnv);
  const res = await handle(req(chat), s.env, { fetchImpl: s.fetchImpl });
  assert.equal(res.status, 200);
  const [c] = s.calls;
  assert.equal(c.url, 'https://api.openai.com/v1/chat/completions');
  assert.equal(c.init.headers.authorization, 'Bearer sk-openai-secret');
  assert.equal(c.init.headers['x-title'], undefined);
  assert.equal(c.body.model, 'gpt-4.1-mini');
  assert.equal(c.body.max_completion_tokens, 1500);
  assert.equal(c.body.max_tokens, undefined);
  assert.ok(!JSON.stringify(c).includes(ID), 'install ID must not reach OpenAI');
});

test('the daily limit works the same with OpenAI', async () => {
  const s = setup({ ...openaiEnv, DAILY_LIMIT: '2' });
  for (let i = 0; i < 2; i++) {
    assert.equal((await handle(req(chat), s.env, { fetchImpl: s.fetchImpl })).status, 200);
  }
  assert.equal((await handle(req(chat), s.env, { fetchImpl: s.fetchImpl })).status, 429);
});

test('a missing key or unknown upstream fails without using a daily call', async () => {
  for (const bad of [{ ...openaiEnv, OPENAI_KEY: undefined }, { UPSTREAM: 'nope' }]) {
    const s = setup(bad);
    const res = await handle(req(chat), s.env, { fetchImpl: s.fetchImpl });
    assert.equal(res.status, 500);
    assert.equal((await res.json()).error.code, 'not_configured');
    assert.equal(s.store.size, 0, 'no call counted');
    assert.equal(s.calls.length, 0);
  }
});
