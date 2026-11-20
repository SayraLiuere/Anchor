/// Address of the Anchor LLM proxy (B1), e.g.
/// `https://anchor-proxy.<your-subdomain>.workers.dev`.
///
/// Paste it here after deploying `proxy/` (see proxy/README.md), or build with
/// `--dart-define=ANCHOR_PROXY_URL=https://...`. While it is empty, the
/// built-in AI is off and Mira uses her template replies. The URL is not a
/// secret; the API key lives only in the Worker.
const proxyUrl = String.fromEnvironment('ANCHOR_PROXY_URL',
    defaultValue: 'https://anchor-proxy.anchor-wellbeing.workers.dev');
