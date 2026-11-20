// Anchor LLM proxy (B1, thesis 5.1) — a Cloudflare Worker.
//
// The app sends OpenAI-format chat requests here with a random install ID;
// this Worker checks them and forwards them to the AI service chosen by
// UPSTREAM (OpenAI or OpenRouter) with the server's key. The key exists only
// as a Worker secret, never in the APK.
//
// Limits: about DAILY_LIMIT calls per install per day (Workers KV counter,
// eventually consistent, so "about"), a model allowlist, a body-size limit
// and a cap on reply tokens. Message content is never logged or stored; the
// install ID is not forwarded to the AI service.

const MAX_BODY_BYTES = 32 * 1024;
const MAX_TOKENS = 1500;
const ROLES = new Set(['system', 'user', 'assistant']);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

/** Where requests go. Both speak the OpenAI chat format. */
export const UPSTREAMS = {
  openrouter: {
    url: 'https://openrouter.ai/api/v1/chat/completions',
    keyVar: 'OPENROUTER_KEY',
    tokensField: 'max_tokens',
    extraHeaders: { 'x-title': 'Anchor' },
  },
  openai: {
    url: 'https://api.openai.com/v1/chat/completions',
    keyVar: 'OPENAI_KEY',
    // Newer OpenAI models reject max_tokens.
    tokensField: 'max_completion_tokens',
    extraHeaders: {},
  },
};

function json(status, body, headers = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json', ...headers },
  });
}

const fail = (status, code, message) => json(status, { error: { code, message } });

/** The day the counter belongs to, in the trial's time zone (default UTC+8). */
export function dayKey(now, offsetMinutes) {
  return new Date(now.getTime() + offsetMinutes * 60_000).toISOString().slice(0, 10);
}

export async function handle(request, env, { fetchImpl = fetch, now = new Date() } = {}) {
  const url = new URL(request.url);
  if (request.method === 'GET' && url.pathname === '/health') return new Response('ok');
  if (request.method !== 'POST' || url.pathname !== '/v1/chat/completions') {
    return fail(404, 'not_found', 'Not found');
  }

  const id = request.headers.get('x-install-id') ?? '';
  if (!UUID.test(id)) return fail(401, 'no_install_id', 'Missing or invalid install ID');

  const declared = Number(request.headers.get('content-length') ?? 0);
  if (declared > MAX_BODY_BYTES) return fail(413, 'too_large', 'Request too large');
  const raw = await request.arrayBuffer();
  if (raw.byteLength > MAX_BODY_BYTES) return fail(413, 'too_large', 'Request too large');

  let body;
  try {
    body = JSON.parse(new TextDecoder().decode(raw));
  } catch {
    return fail(400, 'bad_json', 'Body must be JSON');
  }
  const messages = body?.messages;
  if (!Array.isArray(messages) || messages.length === 0 || messages.length > 40 ||
      !messages.every((m) => ROLES.has(m?.role) && typeof m?.content === 'string')) {
    return fail(400, 'bad_messages', 'messages must be a list of {role, content}');
  }
  if (body.stream) return fail(400, 'no_stream', 'Streaming is not supported');

  const allowed = String(env.ALLOWED_MODELS ?? '').split(',').map((s) => s.trim()).filter(Boolean);
  const model = !body.model || body.model === 'default' ? env.DEFAULT_MODEL : body.model;
  if (!model || !allowed.includes(model)) return fail(400, 'model_not_allowed', 'Model not allowed');

  // A setup mistake must not use up anyone's daily calls, so check it first.
  const target = UPSTREAMS[env.UPSTREAM ?? 'openrouter'];
  const apiKey = target && env[target.keyVar];
  if (!target || !apiKey) return fail(500, 'not_configured', 'The AI service is not set up');

  // Daily limit per install. Counted before forwarding, so failed calls count too.
  const limit = Number(env.DAILY_LIMIT ?? 50);
  const key = `n:${id}:${dayKey(now, Number(env.DAY_OFFSET_MINUTES ?? 480))}`;
  const used = Number((await env.USAGE.get(key)) ?? 0);
  if (used >= limit) {
    return fail(429, 'daily_limit', `Daily limit of ${limit} messages reached. It resets at midnight.`);
  }
  await env.USAGE.put(key, String(used + 1), { expirationTtl: 2 * 24 * 3600 });

  const upstreamBody = {
    model,
    messages: messages.map(({ role, content }) => ({ role, content })),
    [target.tokensField]: Math.min(Number(body.max_tokens) || MAX_TOKENS, MAX_TOKENS),
  };
  if (typeof body.temperature === 'number') upstreamBody.temperature = body.temperature;
  // JSON mode (B4): Mira's chat answers are {reply, notes, facts}. Only this
  // exact value is passed on; other response formats are dropped.
  if (body.response_format?.type === 'json_object') {
    upstreamBody.response_format = { type: 'json_object' };
  }

  let upstream;
  try {
    upstream = await fetchImpl(target.url, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${apiKey}`,
        'content-type': 'application/json',
        ...target.extraHeaders,
      },
      body: JSON.stringify(upstreamBody),
    });
  } catch {
    return fail(502, 'upstream_unreachable', 'The AI service could not be reached');
  }
  const left = { 'x-calls-left': String(Math.max(0, limit - used - 1)) };
  if (!upstream.ok) {
    // Status only: the upstream body can echo the request, so it is not passed on.
    return fail(502, 'upstream_error', `The AI service returned ${upstream.status}`);
  }
  return new Response(upstream.body, {
    status: 200,
    headers: { 'content-type': 'application/json', ...left },
  });
}

export default {
  fetch: (request, env) => handle(request, env),
};
