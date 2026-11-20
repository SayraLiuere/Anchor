import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config.dart' as config;
import '../models/log_entry.dart';
import 'features.dart';
import 'risk_model.dart';

enum LlmProvider {
  /// The Anchor proxy (B1): no key on the phone; the server picks the model.
  proxy('Anchor AI', 'default'),

  /// Developer options: the user's own key, stored in secure storage.
  openai('OpenAI (dev)', 'gpt-4.1-mini'),
  gemini('Gemini (dev)', 'gemini-2.5-flash');

  const LlmProvider(this.label, this.defaultModel);
  final String label;
  final String defaultModel;

  bool get needsKey => this != proxy;
}

/// Provider after loading saved settings (B1). The proxy is the default; a
/// saved OpenAI or Gemini choice is kept only if a key was actually set,
/// since older versions saved "openai" even when no key was ever entered.
LlmProvider providerAfterLoad(String? saved, {required bool hasKey}) {
  final p = LlmProvider.values.asNameMap()[saved];
  if (p == null || (p.needsKey && !hasKey)) return LlmProvider.proxy;
  return p;
}

/// The proxy said this install has used its messages for today (HTTP 429).
class DailyLimitReached implements Exception {
  const DailyLimitReached(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Language-generation layer (thesis Section 4.7).
///
/// Two personas share one grounding: in chat Mira is a playful pet-friend; in
/// weekly recaps it writes like a professional wellbeing report. Only
/// structured, identifier-free context is sent. When no key is set or a call
/// fails, template responses built from the same features are used (NFR5).
class CompanionAI {
  CompanionAI({http.Client? client, this.proxyUrl = config.proxyUrl})
      : _http = client ?? http.Client();

  final http.Client _http;

  /// Base URL of the Anchor proxy; empty when it is not set up yet.
  final String proxyUrl;

  LlmProvider provider = LlmProvider.proxy;
  String apiKey = '';
  String model = LlmProvider.proxy.defaultModel;

  /// Random per-install ID sent to the proxy for its daily limit. Not linked
  /// to the user's name or anything else.
  String installId = '';

  /// Last API error, shown in Settings so problems are visible.
  String? lastError;

  /// True after the proxy refused a call because today's limit was used.
  bool limitReached = false;

  bool get online => provider == LlmProvider.proxy
      ? proxyUrl.isNotEmpty && installId.isNotEmpty
      : apiKey.trim().isNotEmpty;

  static const dailyLimitMessage =
      "I've chatted so much today that my voice is all tired 😴 I'll be back "
      "tomorrow! Your logs and screen time still work, and I'm still keeping you company.";

  static const _safety = '''
Safety rules (always apply):
- You are not a clinician. Never diagnose, never call the user "addicted", never give medical advice.
- Use only the numbers in the structured context; never invent data.
- If the user mentions self-harm, suicide, or being in danger, respond with care and urge them
  to contact emergency services (999 in Malaysia) or Befrienders KL (03-7627 2929) right away.''';

  static const chatPersona = '''
You are Mira, a small, cuddly companion pet who lives in the user's phone and is also their friend.
You help a university student notice and gently reduce problematic smartphone use.
Voice: casual, warm, playful, like texting a close friend. Short sentences. One or two emojis at most.
You can mention your own little pet feelings ("I missed you!", "my ears perked up").
Never lecture or guilt-trip. Celebrate small wins.
Shape of a reply: react to how they feel, maybe one gentle observation from their data,
at most one tiny suggestion, then one light question. Max 60 words.
$_safety''';

  static const recapPersona = '''
You write the weekly reflection report for a digital-wellbeing app used by university students.
Voice: professional, clear and supportive, like a wellbeing coach's written summary. No emojis, no pet talk.
Address the reader as "you". Use exactly these three headings, each on its own line:
Overview, Patterns, Suggestions.
Overview: 1-2 sentences on the week and the current risk level.
Patterns: 2-3 short bullet points citing specific numbers from the data.
Suggestions: 1-2 concrete, achievable bullet points for next week.
Max 180 words.
$_safety''';

  static final _crisis = RegExp(
      r'\b(suicid\w*|kill myself|end my life|self[- ]?harm|hurt myself|want to die)\b',
      caseSensitive: false);

  static bool isCrisis(String text) => _crisis.hasMatch(text);

  static const crisisMessage =
      "I'm really glad you told me, and I care about you a lot. What you're feeling "
      "matters and you deserve support from a real person right now. In Malaysia you can "
      "call Befrienders KL at 03-7627 2929 (24 hours), Talian Kasih at 15999, or 999 in an "
      "emergency. If you can, reach out to someone you trust nearby too. I'll be right here.";

  Map<String, dynamic> _context(BehaviourFeatures f, RiskResult r) => {
        'current_risk_level': r.level.label,
        'risk_reasons': r.reasons,
        'last_7_days': f.toPromptJson(),
      };

  Future<String> reply({
    required String userText,
    required BehaviourFeatures features,
    required RiskResult risk,
    required List<ChatMessage> history,
  }) async {
    if (isCrisis(userText)) return crisisMessage;
    final turns =
        history.length > 8 ? history.sublist(history.length - 8) : history;
    final system =
        '$chatPersona\n\nStructured context from the user\'s own logs:\n${jsonEncode(_context(features, risk))}';
    final messages = [
      for (final m in turns) (m.fromUser ? 'user' : 'assistant', m.text),
      ('user', userText),
    ];
    final text = await _generate(system, messages);
    if (text != null) return text;
    return limitReached ? dailyLimitMessage : _fallbackReply(userText, features, risk);
  }

  Future<String> weeklySummary(BehaviourFeatures features, RiskResult risk) async {
    if (!features.hasData) {
      return 'Overview\nThere is not enough data yet for a weekly report. '
          'Log a few episodes or check-ins, or enable screen time, and a recap will be '
          'generated from your patterns.';
    }
    final user =
        'Write this week\'s report from this data:\n${jsonEncode(_context(features, risk))}';
    return await _generate(recapPersona, [('user', user)]) ??
        _fallbackSummary(features, risk);
  }

  /// Sends a tiny request so Settings can confirm the key and model work.
  Future<String?> testConnection() async {
    final r = await _generate('Reply with the single word: ok', [('user', 'ping')]);
    return r == null ? (lastError ?? 'No response') : null;
  }

  Future<String?> _generate(String system, List<(String, String)> messages) async {
    limitReached = false;
    if (!online) return null;
    try {
      final res = switch (provider) {
        LlmProvider.proxy => await _proxy(system, messages),
        LlmProvider.openai => await _openAi(system, messages),
        LlmProvider.gemini => await _gemini(system, messages),
      };
      lastError = null;
      return res;
    } on DailyLimitReached catch (e) {
      limitReached = true;
      lastError = e.message;
      return null;
    } catch (e) {
      lastError = e.toString().replaceFirst('Exception: ', '');
      return null;
    }
  }

  /// OpenAI-format request to the Anchor proxy. No key: the install ID is
  /// only used by the proxy for its daily limit.
  Future<String> _proxy(String system, List<(String, String)> messages) async {
    final res = await _http
        .post(
          Uri.parse('$proxyUrl/v1/chat/completions'),
          headers: {'Content-Type': 'application/json', 'X-Install-Id': installId},
          body: jsonEncode({
            'model': model.isEmpty ? 'default' : model,
            'messages': [
              {'role': 'system', 'content': system},
              for (final (role, text) in messages) {'role': role, 'content': text},
            ],
            'max_tokens': 1500,
          }),
        )
        .timeout(const Duration(seconds: 30));
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final err = data['error']?['message'];
    if (res.statusCode == 429) throw DailyLimitReached('$err');
    if (res.statusCode != 200) throw Exception('Anchor AI ${res.statusCode}: ${err ?? res.body}');
    final text = data['choices']?[0]?['message']?['content'];
    if (text is! String || text.trim().isEmpty) throw Exception('Empty reply from Anchor AI');
    return text.trim();
  }

  Future<String> _openAi(String system, List<(String, String)> messages) async {
    final res = await _http
        .post(
          Uri.parse('https://api.openai.com/v1/chat/completions'),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ${apiKey.trim()}',
          },
          body: jsonEncode({
            'model': model,
            'messages': [
              {'role': 'system', 'content': system},
              for (final (role, text) in messages) {'role': role, 'content': text},
            ],
            // Generous cap: reasoning models spend part of it before answering.
            'max_completion_tokens': 1500,
          }),
        )
        .timeout(const Duration(seconds: 30));
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode != 200) {
      throw Exception('OpenAI ${res.statusCode}: ${data['error']?['message'] ?? res.body}');
    }
    final text = data['choices']?[0]?['message']?['content'];
    if (text is! String || text.trim().isEmpty) throw Exception('Empty reply from OpenAI');
    return text.trim();
  }

  Future<String> _gemini(String system, List<(String, String)> messages) async {
    final res = await _http
        .post(
          Uri.parse(
              'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent'),
          headers: {
            'Content-Type': 'application/json',
            'x-goog-api-key': apiKey.trim(),
          },
          body: jsonEncode({
            'system_instruction': {
              'parts': [
                {'text': system}
              ]
            },
            'contents': [
              for (final (role, text) in messages)
                {
                  'role': role == 'assistant' ? 'model' : 'user',
                  'parts': [
                    {'text': text}
                  ]
                }
            ],
          }),
        )
        .timeout(const Duration(seconds: 30));
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    if (res.statusCode != 200) {
      throw Exception('Gemini ${res.statusCode}: ${data['error']?['message'] ?? res.body}');
    }
    final text = data['candidates']?[0]?['content']?['parts']?[0]?['text'];
    if (text is! String || text.trim().isEmpty) throw Exception('Empty reply from Gemini');
    return text.trim();
  }

  // ---------- Offline fallbacks (template-based, grounded in features) ----------

  String _fallbackReply(String text, BehaviourFeatures f, RiskResult r) {
    final lower = text.toLowerCase();
    final String ack;
    if (RegExp(r'resist|managed to|put it down|didn.t').hasMatch(lower)) {
      ack = 'Wait, you resisted?! That\'s huge, I\'m doing a little happy spin 🐾';
    } else if (RegExp(r'stress|exam|deadline|assignment|overwhelm').hasMatch(lower)) {
      ack = 'Oof, that sounds like a lot of pressure. Come here, I\'ve got you.';
    } else if (RegExp(r'bored|nothing to do|idle').hasMatch(lower)) {
      ack = 'Boredom is sneaky, it always sends you straight to your phone huh.';
    } else if (RegExp(r"sleep|night|tired|can't sleep").hasMatch(lower)) {
      ack = 'Late nights again? My eyes are getting sleepy just thinking about it 😴';
    } else if (RegExp(r'sad|lonely|down|upset').hasMatch(lower)) {
      ack = "Aw, I'm sorry you're feeling low. I'm right here with you.";
    } else if (RegExp(r'good|great|happy').hasMatch(lower)) {
      ack = 'Yay, I love hearing that!';
    } else {
      ack = 'Thanks for telling me, I always want to hear about your day.';
    }

    final s = f.screen;
    final top = f.topTrigger;
    final observation = s != null && s.socialHours + s.videoHours >= 2
        ? 'You\'ve been averaging ${(s.socialHours + s.videoHours).toStringAsFixed(1)}h a day on social and videos.'
        : top != null
            ? '"${top.label}" keeps showing up before your episodes.'
            : '';

    final suggestion = switch (r.level) {
      RiskLevel.high => 'Wanna try leaving the phone in another room for 30 minutes? I\'ll wait.',
      RiskLevel.medium => 'Maybe mute the noisy apps for an hour?',
      RiskLevel.low => '',
    };

    return [ack, observation, suggestion, 'What\'s going on right now?']
        .where((p) => p.isNotEmpty)
        .join(' ');
  }

  String _fallbackSummary(BehaviourFeatures f, RiskResult r) {
    final top = f.topTrigger;
    final s = f.screen;
    final patterns = <String>[
      if (s != null)
        '- Average screen time was ${s.screenHours.toStringAsFixed(1)} hours a day, '
            'including ${s.socialHours.toStringAsFixed(1)} h on social media and '
            '${s.gamingHours.toStringAsFixed(1)} h on games.',
      if (f.episodeCount > 0)
        '- You logged ${f.episodeCount} episodes (${f.episodesPerDay.toStringAsFixed(1)} per day) '
            'and resisted ${(f.resistRate * 100).round()}% of urges.',
      if (top != null) '- The most frequent trigger was ${top.label.toLowerCase()}.',
      if (f.lateNightRatio >= 0.3 || (s?.lateNightRatio ?? 0) >= 0.1)
        '- A notable share of phone use happened between 23:00 and 05:00.',
    ];
    final suggestions = <String>[
      if (f.lateNightRatio >= 0.3 || (s?.lateNightRatio ?? 0) >= 0.1)
        '- Set a phone-free wind-down period of 30 minutes before bed.',
      if (top == Trigger.stress)
        '- When stress builds, take a two-minute breathing break before unlocking your phone.',
      if (top == Trigger.boredom)
        '- Prepare a short list of three offline activities for idle moments.',
      if (s != null && s.socialHours >= 2)
        '- Try a daily social media limit about 15 minutes below your current average.',
      '- Choose one part of the day to keep your phone out of reach.',
    ].take(2);
    return 'Overview\nThis week your estimated risk level is ${r.level.label.toLowerCase()}. '
        '${r.reasons.isEmpty ? '' : 'The main contributing factor was: ${r.reasons.first.toLowerCase()}.'}\n\n'
        'Patterns\n${patterns.join('\n')}\n\n'
        'Suggestions\n${suggestions.join('\n')}';
  }
}
