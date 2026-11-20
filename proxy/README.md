# Anchor LLM proxy (B1)

A small Cloudflare Worker between the app and the AI service, so
participants get AI replies without an API key on their phone.

```
Anchor app ──(OpenAI-format request + random install ID)──▶ Worker ──(server key)──▶ OpenAI or OpenRouter
```

`UPSTREAM` in `wrangler.toml` picks the service. It is set to **OpenAI**
for now; OpenRouter (many models behind one key) is a config switch away,
with no app rebuild.

What it enforces (`src/worker.js`):

- **Key stays on the server.** The API key is a Worker secret. It is not in
  the APK or the repo.
- **About 50 calls per install per day**, counted per local day (UTC+8). The
  51st call gets HTTP 429, and Mira says she's tired and will be back tomorrow.
- **Model allowlist.** The app asks for `default`; the Worker decides which
  model that is (`DEFAULT_MODEL`).
- **Request limits:** bodies over 32 KB are refused, replies are capped at 1500
  tokens, and streaming is off.
- **No content logging.** Observability is off, and nothing about messages is
  stored. The install ID is a random UUID; it is used for the counter only and
  is not sent to the AI service.
- **Setup mistakes** (missing key, unknown `UPSTREAM`) return an error without
  using up anyone's daily calls.

## Test locally (no account needed)

```
cd proxy
node --test                     # unit tests
node dev-server.js              # fake replies on http://localhost:8787
DAILY_LIMIT=3 node dev-server.js
```

Build the app against it (the emulator reaches your PC at 10.0.2.2; debug
builds allow plain HTTP to that address only):

```
flutter build apk --debug --dart-define=ANCHOR_PROXY_URL=http://10.0.2.2:8787
```

## Deploy (with OpenAI)

You do these steps yourself: they need your accounts and keys. Never paste
the key into a file, a chat or the app.

1. **OpenAI:** at platform.openai.com, create an API key for this project
   (a separate key from any other you use), and set a **monthly budget limit**
   in your organization's billing or limits settings, e.g. USD 5, so a bug or
   misuse can never cost more than that.
2. **Cloudflare:** create a free account at dash.cloudflare.com.
3. In this folder, log in and create the counter store:
   ```
   npx wrangler login
   npx wrangler kv namespace create USAGE
   ```
   Paste the printed `id` into `wrangler.toml` (replace `PASTE_THE_KV_NAMESPACE_ID_HERE`).
4. Store the key as a secret (you type it in; it is never saved in a file):
   ```
   npx wrangler secret put OPENAI_KEY
   ```
5. Check the model in `wrangler.toml` (`DEFAULT_MODEL` and `ALLOWED_MODELS`,
   currently `gpt-4.1-mini`).
6. Deploy:
   ```
   npx wrangler deploy
   ```
   It prints the address, like `https://anchor-proxy.<you>.workers.dev`.
7. Check it: open `https://anchor-proxy.<you>.workers.dev/health` in a browser;
   it should say `ok`.
8. Put the address in `lib/config.dart` (the `defaultValue`), rebuild the app,
   and install it with `adb install -r`.

## Switching to OpenRouter later

1. Create an OpenRouter key with a credit limit.
2. In `wrangler.toml`: `UPSTREAM = "openrouter"`, and use OpenRouter model IDs,
   e.g. `DEFAULT_MODEL = "openai/gpt-4.1-mini"` (check IDs and prices on
   openrouter.ai/models).
3. `npx wrangler secret put OPENROUTER_KEY`, then `npx wrangler deploy`.

The app does not change. You can delete the old `OPENAI_KEY` secret with
`npx wrangler secret delete OPENAI_KEY`.

## Costs and limits to know

- Workers free plan: 100,000 requests a day.
- Workers KV free plan: 1,000 writes a day, and each chat call is one write.
  That is enough for about 20 participants at 50 calls each; real use is
  usually far lower. More needs the Workers Paid plan.
- Model cost depends on the model, so the budget limit on the key is the real
  safety net.
- For the thesis (privacy): OpenAI and OpenRouter each have their own data
  retention policies for API requests; cite the one you use. Only anonymous
  numbers and the text participants type are sent, never names or app names.
